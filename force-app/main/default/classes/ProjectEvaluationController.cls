// ProjectEvaluationController.cls
public with sharing class ProjectEvaluationController {
    @AuraEnabled(cacheable=false)
    public static List<SkillEvaluatorService.CandidateResult> evaluateProjectForUI(Id projectId, Integer topN) {
        return SkillEvaluatorService.evaluateProject(projectId, topN);
    }
}