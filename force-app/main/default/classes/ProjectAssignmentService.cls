// ProjectAssignmentService.cls
// Purpose: Create a Project_Assignment__c as a PROPOSED request (to be approved by HR),
//          while preventing duplicate active assignments and enforcing the rule:
//          "One employee can have only ONE Confirmed assignment at a time."

public with sharing class ProjectAssignmentService {

    @AuraEnabled
    public static Id createAssignment(Id projectId, Id employeeId) {

        // 1) Basic validation
        if (projectId == null || employeeId == null) {
            throw new AuraHandledException('Project and Employee are required.');
        }

        // 2) Prevent duplicate ACTIVE assignment for the SAME project+employee
        //    Allow re-assignment only after the previous one is Released (history preserved).
        List<Project_Assignment__c> existingSame = [
            SELECT Id, Status__c
            FROM Project_Assignment__c
            WHERE Project__c = :projectId
              AND Employee__c = :employeeId
              AND Status__c != 'Released'
            LIMIT 1
        ];

        if (!existingSame.isEmpty()) {
            throw new AuraHandledException(
                'An active assignment already exists for this employee on this project.'
            );
        }

        // 3) Enforce "one project at a time" based on CONFIRMED assignments
        //    If the employee is already Confirmed on another project, block creating a new proposal.
        List<Project_Assignment__c> confirmedElsewhere = [
            SELECT Id, Project__c
            FROM Project_Assignment__c
            WHERE Employee__c = :employeeId
              AND Status__c = 'Confirmed'
              AND Project__c != :projectId
            LIMIT 1
        ];

        if (!confirmedElsewhere.isEmpty()) {
            throw new AuraHandledException(
                'Employee is already allocated (confirmed) on another project.'
            );
        }

        // 4) Create as Proposed (HR approval will move it to Confirmed or Rejected)
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