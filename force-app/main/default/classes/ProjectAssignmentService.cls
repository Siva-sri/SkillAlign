// ProjectAssignmentService.cls
public with sharing class ProjectAssignmentService {

    @AuraEnabled
    public static Id createAssignment(Id projectId, Id employeeId) {

        // Basic validation
        if (projectId == null || employeeId == null) {
            throw new AuraHandledException('Project and Employee are required.');
        }

        // Optional: prevent duplicate assignments
        List<Project_Assignment__c> existing = [
            SELECT Id
            FROM Project_Assignment__c
            WHERE Project__c = :projectId
            AND Employee__c = :employeeId
            LIMIT 1
        ];

        if (!existing.isEmpty()) {
            throw new AuraHandledException('Employee is already assigned to this project.');
        }

        Project_Assignment__c assignment = new Project_Assignment__c(
            Project__c = projectId,
            Employee__c = employeeId,
            Assigned_Date__c = Date.today(),
            Status__c = 'Proposed'
        );

        insert assignment;
        return assignment.Id;
    }
}