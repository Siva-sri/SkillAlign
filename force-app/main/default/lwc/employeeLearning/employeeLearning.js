import { LightningElement, api, track, wire } from 'lwc';
import getRecommendations from '@salesforce/apex/EmployeeLearningService.getRecommendations';
import addToPlan from '@salesforce/apex/EmployeeLearningService.addToPlan';
import updatePlanStatus from '@salesforce/apex/EmployeeLearningService.updatePlanStatus';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';

export default class EmployeeLearning extends LightningElement {
    @api recordId;

    @track loading = false;
    @track error;

    @track topSkills = [];
    @track recommendedActions = [];
    @track myPlan = [];

    topSkillCount = 10;
    actionsPerSkill = 5;

    topSkillsCollapsedCount = 3;
    actionsCollapsedCount = 5;

    showAllTopSkills = false;
    showAllActions = false;

    wiredResp; // <-- store wired response for refreshApex

    // ---------- Picklist ----------
    get statusOptions() {
        return [
            { label: 'Not Started', value: 'Not Started' },
            { label: 'In Progress', value: 'In Progress' },
            { label: 'Completed', value: 'Completed' },
            { label: 'Approved', value: 'Approved' }
        ];
    }

    // ---------- Tab Labels (with spacing) ----------
    get tabLabelRecommendations() {
        const count = this.recommendedActions?.length || 0;
        return `Recommendations (${count})\u00A0\u00A0\u00A0`;
    }
    get tabLabelPlan() {
        const count = this.myPlan?.length || 0;
        return `\u00A0\u00A0My Plan (${count})`;
    }

    // ---------- Visible lists ----------
    get visibleTopSkills() {
        return this.showAllTopSkills
            ? this.topSkills
            : (this.topSkills || []).slice(0, this.topSkillsCollapsedCount);
    }
    get visibleRecommendedActions() {
        return this.showAllActions
            ? this.recommendedActions
            : (this.recommendedActions || []).slice(0, this.actionsCollapsedCount);
    }

    get showTopSkillsToggle() {
        return (this.topSkills || []).length > this.topSkillsCollapsedCount;
    }
    get showActionsToggle() {
        return (this.recommendedActions || []).length > this.actionsCollapsedCount;
    }

    get topSkillsToggleLabel() {
        return this.showAllTopSkills ? 'Show less' : 'Show more';
    }
    get actionsToggleLabel() {
        return this.showAllActions ? 'Show less' : 'Show more';
    }

    toggleTopSkills() {
        this.showAllTopSkills = !this.showAllTopSkills;
    }
    toggleActions() {
        this.showAllActions = !this.showAllActions;
    }

    // ---------- DATA LOAD (wire) ----------
    @wire(getRecommendations, {
        employeeId: '$recordId',
        topSkillCount: '$topSkillCount',
        actionsPerSkill: '$actionsPerSkill'
    })
    wiredRecommendations(resp) {
        this.wiredResp = resp;

        const { data, error } = resp;
        if (data) {
            this.error = null;
            this.topSkills = data.topSkills || [];
            this.recommendedActions = data.recommendedActions || [];
            this.myPlan = data.myPlan || [];

            // optional reset on reload
            this.showAllTopSkills = false;
            this.showAllActions = false;
        } else if (error) {
            this.error = this.normalizeError(error);
        }
    }

    // ---------- Actions ----------
    async handleAddToPlan(event) {
        const actionId = event.currentTarget.dataset.actionId;
        if (!actionId) return;

        this.loading = true;
        try {
            await addToPlan({ employeeId: this.recordId, learningActionId: actionId });
            this.showToast('Added', 'Learning action added to your plan.', 'success');

            // ✅ refresh wired cache so My Plan updates immediately
            await refreshApex(this.wiredResp);

        } catch (e) {
            this.showToast('Error', this.normalizeError(e), 'error');
        } finally {
            this.loading = false;
        }
    }

    async handleStatusChange(event) {
        const planId = event.currentTarget.dataset.planId;
        const newStatus = event.detail.value;
        if (!planId || !newStatus) return;

        this.loading = true;
        try {
            await updatePlanStatus({ employeeLearningActionId: planId, newStatus });
            this.showToast('Updated', `Status set to "${newStatus}".`, 'success');

            // ✅ refresh wired cache
            await refreshApex(this.wiredResp);

        } catch (e) {
            this.showToast('Error', this.normalizeError(e), 'error');
        } finally {
            this.loading = false;
        }
    }

    // ---------- Utils ----------
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    normalizeError(err) {
        if (!err) return 'Unknown error';
        if (Array.isArray(err.body)) return err.body.map(e => e.message).join(', ');
        if (err.body && err.body.message) return err.body.message;
        if (err.message) return err.message;
        try { return JSON.stringify(err); } catch { return 'Unknown error'; }
    }
}
