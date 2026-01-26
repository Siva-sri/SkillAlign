// SkillEvaluatorService.cls
// Purpose: Evaluate employee fit for a project by comparing required skills vs employee skill levels,
//          compute a gap score, and create/update Project_Candidate__c records for the top N.

public with sharing class SkillEvaluatorService {

    public class CandidateResult {
        @AuraEnabled public Id employeeId;
        @AuraEnabled public String employeeName;
        @AuraEnabled public Decimal gapScore;
        @AuraEnabled public Map<String, Integer> deficitsBySkill; // Skill Name -> deficit points (now = penalty points)
        @AuraEnabled public String details;
        @AuraEnabled public Datetime evaluatedAt;

        public CandidateResult(Id empId, String empName) {
            employeeId = empId;
            employeeName = empName;
            gapScore = 0;
            deficitsBySkill = new Map<String, Integer>();
            details = '';
            evaluatedAt = System.now();
        }
    }

    private class CandidateComparator implements System.Comparator<CandidateResult> {
        public Integer compare(CandidateResult x, CandidateResult y) {
            if (x.gapScore != y.gapScore) {
                return (x.gapScore < y.gapScore) ? -1 : 1;
            }
            String xn = (x.employeeName == null) ? '' : x.employeeName;
            String yn = (y.employeeName == null) ? '' : y.employeeName;
            return xn.toLowerCase().compareTo(yn.toLowerCase());
        }
    }

    @AuraEnabled
    public static List<CandidateResult> evaluateProject(Id projectId, Integer topN) {
        if (projectId == null) return new List<CandidateResult>();

        Project__c proj = [
            SELECT Id, Name
            FROM Project__c
            WHERE Id = :projectId
            LIMIT 1
        ];

        // 1) Load project requirements (MIN CHANGE: add Importance__c, Weight__c)
        List<Project_Skill_Requirement__c> reqs = [
            SELECT Skill__c, Skill__r.Name, Required_Level__c, Importance__c, Weight__c
            FROM Project_Skill_Requirement__c
            WHERE Project__c = :projectId
        ];
        if (reqs.isEmpty()) return new List<CandidateResult>();

        Set<Id> requiredSkillIds = new Set<Id>();
        Map<Id, Integer> requiredLevelBySkill = new Map<Id, Integer>();
        Map<Id, String> skillNameById = new Map<Id, String>();

        // NEW: importance multiplier by skill (Required=2, Nice-to-Have=1)
        Map<Id, Integer> importanceMultiplierBySkill = new Map<Id, Integer>();

        // NEW: weight by skill (default 1)
        Map<Id, Integer> weightBySkill = new Map<Id, Integer>();

        for (Project_Skill_Requirement__c r : reqs) {
            if (r.Skill__c == null) continue;
            requiredSkillIds.add(r.Skill__c);

            Integer reqLevel = (r.Required_Level__c == null) ? 0 : Integer.valueOf(r.Required_Level__c);
            requiredLevelBySkill.put(r.Skill__c, reqLevel);

            skillNameById.put(r.Skill__c, (r.Skill__r != null) ? r.Skill__r.Name : 'Skill');

            // Importance -> multiplier
            // If Importance__c is blank or unexpected, treat as Nice-to-Have (soft) to avoid harsh scoring.
            Integer mult = (r.Importance__c == 'Required') ? 2 : 1;
            importanceMultiplierBySkill.put(r.Skill__c, mult);

            // Weight default = 1
            Integer w = 1;
            if (r.Weight__c != null) {
                // Weight__c is Number, store as integer points
                w = Integer.valueOf(r.Weight__c);
                if (w <= 0) w = 1; // guardrail
            }
            weightBySkill.put(r.Skill__c, w);
        }

        if (requiredSkillIds.isEmpty()) return new List<CandidateResult>();

        // 2) Load employees
        List<Employee__c> employees = [
            SELECT Id, Name
            FROM Employee__c
            WHERE Id != null
        ];
        if (employees.isEmpty()) return new List<CandidateResult>();

        Set<Id> employeeIds = new Set<Id>();
        for (Employee__c e : employees) employeeIds.add(e.Id);

        // 3) Load employee skills relevant to requirements
        List<Employee_Skill__c> empSkills = [
            SELECT Employee__c, Skill__c, Level__c
            FROM Employee_Skill__c
            WHERE Employee__c IN :employeeIds
              AND Skill__c IN :requiredSkillIds
        ];

        Map<Id, Map<Id, Integer>> levelByEmployeeBySkill = new Map<Id, Map<Id, Integer>>();
        for (Employee_Skill__c es : empSkills) {
            if (es.Employee__c == null || es.Skill__c == null) continue;

            if (!levelByEmployeeBySkill.containsKey(es.Employee__c)) {
                levelByEmployeeBySkill.put(es.Employee__c, new Map<Id, Integer>());
            }
            Integer lvl = (es.Level__c == null) ? 0 : Integer.valueOf(es.Level__c);
            levelByEmployeeBySkill.get(es.Employee__c).put(es.Skill__c, lvl);
        }

        // 4) Evaluate
        List<CandidateResult> results = new List<CandidateResult>();

        for (Employee__c emp : employees) {
            CandidateResult cr = new CandidateResult(emp.Id, emp.Name);

            // Total penalty points (not raw deficit anymore)
            Integer totalPenalty = 0;
            List<String> detailParts = new List<String>();

            Map<Id, Integer> empLevels = levelByEmployeeBySkill.get(emp.Id);

            for (Id skillId : requiredSkillIds) {
                Integer required = requiredLevelBySkill.get(skillId);
                if (required == null) required = 0;

                Integer hasLevel = 0;
                if (empLevels != null && empLevels.containsKey(skillId)) {
                    hasLevel = empLevels.get(skillId);
                }

                Integer deficit = required - hasLevel;
                if (deficit < 0) deficit = 0;

                if (deficit > 0) {
                    Integer mult = importanceMultiplierBySkill.containsKey(skillId)
                        ? importanceMultiplierBySkill.get(skillId)
                        : 1;

                    Integer w = weightBySkill.containsKey(skillId)
                        ? weightBySkill.get(skillId)
                        : 1;

                    Integer penalty = deficit * mult * w;
                    totalPenalty += penalty;

                    String skName = skillNameById.get(skillId);
                    if (String.isBlank(skName)) skName = 'Skill';

                    // deficitsBySkill now stores penalty points (still Integer)
                    Integer existing = cr.deficitsBySkill.containsKey(skName) ? cr.deficitsBySkill.get(skName) : 0;
                    cr.deficitsBySkill.put(skName, existing + penalty);

                    // Make details explainable (minimal extra text)
                    String impLabel = (mult == 2) ? 'Required' : 'Nice-to-Have';
                    detailParts.add(
                        skName + ' (' + impLabel + ', w ' + w + '): req ' + required + ', has ' + hasLevel +
                        ', deficit ' + deficit + ' => ' + penalty
                    );
                }
            }

            cr.gapScore = Decimal.valueOf(totalPenalty);
            cr.evaluatedAt = System.now();
            cr.details = (detailParts.isEmpty())
                ? 'Ready (no skill gaps)'
                : String.join(detailParts, '; ');

            results.add(cr);
        }

        // 5) Sort
        results.sort(new CandidateComparator());

        // 6) topN trimming
        Integer limitN = (topN == null || topN <= 0) ? results.size() : Math.min(topN, results.size());
        List<CandidateResult> topResults = new List<CandidateResult>();
        for (Integer i = 0; i < limitN; i++) {
            topResults.add(results[i]);
        }

        // 7) Persist
        upsertProjectCandidates(projectId, proj.Name, topResults);

        return topResults;
    }

    private static void upsertProjectCandidates(Id projectId, String projectName, List<CandidateResult> topResults) {
        if (topResults == null || topResults.isEmpty()) return;

        Datetime nowDt = System.now();
        List<Project_Candidate__c> candidates = new List<Project_Candidate__c>();

        for (CandidateResult r : topResults) {
            Project_Candidate__c pc = new Project_Candidate__c();

            pc.Project__c = projectId;
            pc.Employee__c = r.employeeId;

            pc.Project_Employee_Key__c = String.valueOf(projectId) + '|' + String.valueOf(r.employeeId);

            pc.Gap_Score__c = r.gapScore;
            pc.Is_Project_Ready__c = (r.gapScore != null && r.gapScore == 0);
            pc.Last_Evaluated__c = nowDt;
            pc.Details__c = r.details;

            candidates.add(pc);
        }
        upsert candidates Project_Employee_Key__c;
    }
}