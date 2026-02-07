public with sharing class SkillEvaluatorService {

    // Structured detail returned per skill for UI
    public class SkillGapDetail {
        @AuraEnabled public String skillName;
        @AuraEnabled public Integer requiredLevel;
        @AuraEnabled public Integer hasLevel;        
        @AuraEnabled public Integer effectiveLevel;  // Reduce from Last verified date and Source of skill
        @AuraEnabled public Integer deficit;
        @AuraEnabled public String importance;       // Required or Nice-to-Have
        @AuraEnabled public Integer weight;
        @AuraEnabled public Integer impact;          // what this gap contributes to total gap score
        @AuraEnabled public String reason;           // short reason for UI tooltips
        @AuraEnabled public String source;           // Self-assessment / Manager-assessed
        @AuraEnabled public Date lastVerifiedDate;   // Last_Verified_Date__c

        public SkillGapDetail(
            String skillName,
            Integer req,
            Integer has,
            Integer effective,
            Integer deficit,
            String importance,
            Integer weight,
            Integer impact,
            String source,
            Date lastVerifiedDate
        ) {
            this.skillName = skillName;
            this.requiredLevel = req;
            this.hasLevel = has;
            this.effectiveLevel = effective;
            this.deficit = deficit;
            this.importance = importance;
            this.weight = weight;
            this.impact = impact;
            this.source = source;
            this.lastVerifiedDate = lastVerifiedDate;
            this.reason = '';
        }
    }

    public class CandidateResult {
        @AuraEnabled public Id employeeId;
        @AuraEnabled public String employeeName;
        @AuraEnabled public Decimal gapScore;                            // Total of all impact 
        @AuraEnabled public Map<String, Integer> deficitsBySkill;        // Skill Name -> Impact 
        @AuraEnabled public String details;
        @AuraEnabled public Datetime evaluatedAt;
        @AuraEnabled public List<SkillGapDetail> deficitsDetailed;

        public CandidateResult(Id empId, String empName) {
            employeeId = empId;
            employeeName = empName;
            gapScore = 0;
            deficitsBySkill = new Map<String, Integer>();
            details = '';
            evaluatedAt = System.now();
            deficitsDetailed = new List<SkillGapDetail>();
        }
    }
    // Sort candidates according to Gap Score, used when we call listName.sort()
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
        // If UI calls without Id, return empty list
        if (projectId == null) return new List<CandidateResult>();
        // Get Project details from ID from Record page
        Project__c proj = [
            SELECT Id, Name, Project_Manager__c
            FROM Project__c
            WHERE Id = :projectId
            LIMIT 1
        ];
        // Project Manager should not be recommended as Candidate
        Id pmId = proj.Project_Manager__c;
        
        // Get Project Requirements with Skills, Level, Importance, Weight
        List<Project_Skill_Requirement__c> reqs = [
            SELECT Skill__c, Skill__r.Name, Required_Level__c, Importance__c, Weight__c
            FROM Project_Skill_Requirement__c
            WHERE Project__c = :projectId
        ];
        if (reqs.isEmpty()) return new List<CandidateResult>();
        
        // Convert records to fast access Maps
        Set<Id> requiredSkillIds = new Set<Id>();
        Map<Id, Integer> requiredLevelBySkill = new Map<Id, Integer>();
        Map<Id, String> skillNameById = new Map<Id, String>();
        Map<Id, Integer> importanceMultiplierBySkill = new Map<Id, Integer>();
        Map<Id, Integer> weightBySkill = new Map<Id, Integer>();

        for (Project_Skill_Requirement__c r : reqs) {
            if (r.Skill__c == null) continue;
			// Skill record IDs
            requiredSkillIds.add(r.Skill__c);
            
            // Skill ID -> Required Level
            Integer reqLevel = (r.Required_Level__c == null) ? 0 : Integer.valueOf(r.Required_Level__c);
            requiredLevelBySkill.put(r.Skill__c, reqLevel);
            
            // Skill ID -> Importance Level (Required = 2, Nice-to-have = 1)
            skillNameById.put(r.Skill__c, (r.Skill__r != null) ? r.Skill__r.Name : 'Skill');
            Integer mult = (r.Importance__c == 'Required') ? 2 : 1;
            importanceMultiplierBySkill.put(r.Skill__c, mult);
            
            // Skill ID -> Weight (If Required = 2, how much it is required vice-versa)
            Integer w = 1;
            if (r.Weight__c != null) {
                w = Integer.valueOf(r.Weight__c);
                if (w <= 0) w = 1;
            }
            weightBySkill.put(r.Skill__c, w);
        }
        
        // If No skills for current project, return empty list
        if (requiredSkillIds.isEmpty()) return new List<CandidateResult>();
        
        // Select all Unallocated Employees, not Select Project Manager
        List<Employee__c> employees;
        if (pmId == null) {
            employees = [
                SELECT Id, Name
                FROM Employee__c
                WHERE Is_Allocated__c = false
            ];
        } else {
            employees = [
                SELECT Id, Name
                FROM Employee__c
                WHERE Is_Allocated__c = false
                AND Id != :pmId
            ];
        }
        
        // If no employees, return empty list
        if (employees.isEmpty()) return new List<CandidateResult>();
        
        // Collect Employee IDs for fast retrieval
        Set<Id> employeeIds = new Set<Id>();
        for (Employee__c e : employees) employeeIds.add(e.Id);
        
        // Get Employee Skills of employees with the respective project skills
        List<Employee_Skill__c> empSkills = [
            SELECT Employee__c, Skill__c, Level__c, Source__c, Last_Verified_Date__c
            FROM Employee_Skill__c
            WHERE Employee__c IN :employeeIds
            AND Skill__c IN :requiredSkillIds
        ];

        // Maps for evaluation
        Map<Id, Map<Id, Integer>> rawLevelByEmployeeBySkill = new Map<Id, Map<Id, Integer>>();        // <Emp ID,<Skill Id, Level>>
        Map<Id, Map<Id, Integer>> effectiveLevelByEmployeeBySkill = new Map<Id, Map<Id, Integer>>(); //<Emp ID,<Skill Id, Level>> after reducing confidence and year
        Map<Id, Map<Id, String>> sourceByEmployeeBySkill = new Map<Id, Map<Id, String>>();           // <Emp ID, <Skill Id, Source>> 
        Map<Id, Map<Id, Date>> lastVerifiedByEmployeeBySkill = new Map<Id, Map<Id, Date>>();         // <Emp ID, <Skill Id, Last Verified Date>>

        // Date cutoff => Subtract 1 year from TODAY
        Date staleCutoff = Date.today().addMonths(-12);
        // Source Picklist values
        String SELF = 'Self-assessment';
        String MGR  = 'Manager-assessed';

        for (Employee_Skill__c es : empSkills) {
            if (es.Employee__c == null || es.Skill__c == null) continue;

            if (!rawLevelByEmployeeBySkill.containsKey(es.Employee__c)) {
                rawLevelByEmployeeBySkill.put(es.Employee__c, new Map<Id, Integer>());
                effectiveLevelByEmployeeBySkill.put(es.Employee__c, new Map<Id, Integer>());
                sourceByEmployeeBySkill.put(es.Employee__c, new Map<Id, String>());
                lastVerifiedByEmployeeBySkill.put(es.Employee__c, new Map<Id, Date>());
            }

            Integer rawLvl = (es.Level__c == null) ? 0 : Integer.valueOf(es.Level__c);
            
            // "Manager-assessed" => Not reduce Level
            // "Self-assessment"  => Reduce Level
            String src = String.isBlank(es.Source__c) ? SELF : String.valueOf(es.Source__c);
            Boolean isTrusted = (src == MGR);

            Integer confidenceAdjust = isTrusted ? 0 : 1;

            Integer afterConfidence = rawLvl - confidenceAdjust;
            if (afterConfidence < 0) afterConfidence = 0;
            
            // If Last_Verified_Date__c is blank => reduce by 2
            // If older than 12 months => reduce by 1
            // Else => 0
            Date lastVerified = es.Last_Verified_Date__c;
            Integer stalenessAdjust = 0;

            if (lastVerified == null) {
                stalenessAdjust = 2;
            } else if (lastVerified <= staleCutoff) {
                stalenessAdjust = 1;
            }

            Integer effectiveLvl = afterConfidence - stalenessAdjust;
            if (effectiveLvl < 0) effectiveLvl = 0;

            rawLevelByEmployeeBySkill.get(es.Employee__c).put(es.Skill__c, rawLvl);
            effectiveLevelByEmployeeBySkill.get(es.Employee__c).put(es.Skill__c, effectiveLvl);
            sourceByEmployeeBySkill.get(es.Employee__c).put(es.Skill__c, src);
            lastVerifiedByEmployeeBySkill.get(es.Employee__c).put(es.Skill__c, lastVerified);
        }

        List<CandidateResult> results = new List<CandidateResult>();

        for (Employee__c emp : employees) {
            CandidateResult cr = new CandidateResult(emp.Id, emp.Name);

            Integer totalImpact = 0;
            List<String> detailParts = new List<String>();

            Map<Id, Integer> empRawLevels = rawLevelByEmployeeBySkill.get(emp.Id);
            Map<Id, Integer> empEffectiveLevels = effectiveLevelByEmployeeBySkill.get(emp.Id);
            Map<Id, String> empSources = sourceByEmployeeBySkill.get(emp.Id);
            Map<Id, Date> empLastVerified = lastVerifiedByEmployeeBySkill.get(emp.Id);

            for (Id skillId : requiredSkillIds) {
                Integer required = requiredLevelBySkill.get(skillId);
                if (required == null) required = 0;

                Integer rawHas = 0;
                if (empRawLevels != null && empRawLevels.containsKey(skillId)) {
                    rawHas = empRawLevels.get(skillId);
                }

                Integer effectiveHas = rawHas;
                if (empEffectiveLevels != null && empEffectiveLevels.containsKey(skillId)) {
                    effectiveHas = empEffectiveLevels.get(skillId);
                }
                
                String src = SELF;
                if (empSources != null && empSources.containsKey(skillId) && !String.isBlank(empSources.get(skillId))) {
                    src = empSources.get(skillId);
                }

                Date lastVerified = null;
                if (empLastVerified != null && empLastVerified.containsKey(skillId)) {
                    lastVerified = empLastVerified.get(skillId);
                }

                Integer deficit = required - effectiveHas;
                if (deficit < 0) deficit = 0;

                if (deficit > 0) {
                    Integer mult = importanceMultiplierBySkill.containsKey(skillId)
                        ? importanceMultiplierBySkill.get(skillId)
                        : 1;

                    Integer w = weightBySkill.containsKey(skillId)
                        ? weightBySkill.get(skillId)
                        : 1;

                    Integer impact = deficit * mult * w;
                    totalImpact += impact;

                    String skName = skillNameById.get(skillId);
                    if (String.isBlank(skName)) skName = 'Skill';

                    Integer existing = cr.deficitsBySkill.containsKey(skName) ? cr.deficitsBySkill.get(skName) : 0;
                    cr.deficitsBySkill.put(skName, existing + impact);

                    String importanceLabel = (mult == 2) ? 'Required' : 'Nice-to-Have';

                    SkillGapDetail d = new SkillGapDetail(
                        skName,
                        required,
                        rawHas,
                        effectiveHas,
                        deficit,
                        importanceLabel,
                        w,
                        impact,
                        src,
                        lastVerified
                    );

                    List<String> reasons = new List<String>();

                    // Importance/weight reason
                    if (importanceLabel == 'Required' && w >= 3) {
                        reasons.add('High impact: required and heavily weighted for this project.');
                    } else if (importanceLabel == 'Required') {
                        reasons.add('High impact: required skill for the project.');
                    } else if (w >= 3) {
                        reasons.add('Medium impact: nice-to-have but heavily weighted here.');
                    } else {
                        reasons.add('Lower impact: nice-to-have or low weight.');
                    }

                    // Confidence reason (only if it actually changed effective level)
                    // If rawHas != effectiveHas, it could be confidence and/or staleness.
                    // We add confidence message only when source is not manager-assessed AND rawHas dropped at least by 1.
                    if (src != MGR && rawHas > effectiveHas) {
                        reasons.add('Confidence adjusted: skill is not manager-assessed.');
                    }
                    
                    if (lastVerified == null) {
                        reasons.add('Staleness adjusted: skill has never been verified.');
                    } else if (lastVerified <= staleCutoff) {
                        reasons.add('Staleness adjusted: skill last verified over 12 months ago.');
                    }

                    d.reason = String.join(reasons, ' ');
                    cr.deficitsDetailed.add(d);

                    // Details text (readable)
                    String levelNote = (rawHas != effectiveHas)
                        ? ('has ' + rawHas + ' (effective ' + effectiveHas + ')')
                        : ('has ' + rawHas);

                    detailParts.add(
                        skName + ' (' + importanceLabel + ', w ' + w + ', ' + src + '): req ' + required + ', ' +
                        levelNote + ', deficit ' + deficit + ' => impact ' + impact
                    );
                }
            }

            cr.gapScore = Decimal.valueOf(totalImpact);
            cr.evaluatedAt = System.now();
            cr.details = (detailParts.isEmpty())
                ? 'Ready (no skill gaps)'
                : String.join(detailParts, '; ');

            results.add(cr);
        }

        results.sort(new CandidateComparator());

        Integer limitN = (topN == null || topN <= 0) ? results.size() : Math.min(topN, results.size());
        List<CandidateResult> topResults = new List<CandidateResult>();
        for (Integer i = 0; i < limitN; i++) {
            topResults.add(results[i]);
        }

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