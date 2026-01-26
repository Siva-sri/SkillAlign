import { LightningElement, api, track } from 'lwc';
import evaluateProjectForUI from '@salesforce/apex/ProjectEvaluationController.evaluateProjectForUI';
import createAssignment from '@salesforce/apex/ProjectAssignmentService.createAssignment';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class ProjectReadinessDashboard extends LightningElement {
    @api recordId;

    @track candidates = [];
    @track loading = false;
    topN = 10;

    handleEvaluate() {
        if (!this.recordId) {
            this.showToast('Error', 'No project selected (recordId is missing).', 'error');
            return;
        }

        this.loading = true;

        evaluateProjectForUI({ projectId: this.recordId, topN: this.topN })
            .then((results) => {
                const safeResults = results || [];

                this.candidates = safeResults.map(r => {
                    const deficitsObj = r.deficitsBySkill || {};
                    const deficitsList = Object.keys(deficitsObj).map(skillName => ({
                        skillName,
                        deficit: deficitsObj[skillName]
                    }));

                    let gapRows = null;
                    if (Array.isArray(r.deficitsDetailed) && r.deficitsDetailed.length > 0) {
                        gapRows = r.deficitsDetailed.map(item => ({
                            skillName: item.skillName,
                            requiredLevel: item.requiredLevel,
                            hasLevel: item.hasLevel,
                            deficit: item.deficit,
                            importance: item.importance,
                            weight: item.weight,
                            penalty: item.penalty,
                            reason: item.reason
                            // percentOfTotal REMOVED
                        }));
                    }

                    const employeeId = r.employeeId;

                    return {
                        employeeId,
                        employeeName: r.employeeName,
                        gapScore: r.gapScore,
                        isReady: r.gapScore === 0,

                        deficitsList,
                        hasDeficits: deficitsList.length > 0,

                        details: r.details || '',
                        gapRows,

                        // Details toggle state (per employee)
                        showDetails: false,
                        detailsIcon: 'utility:chevronright'
                    };
                });

                if (this.candidates.length === 0) {
                    this.showToast(
                        'Info',
                        'No candidates returned. Ensure the project has skill requirements and employees have skills.',
                        'info'
                    );
                }
            })
            .catch((err) => {
                this.showToast('Error', this.normalizeError(err), 'error');
            })
            .finally(() => {
                this.loading = false;
            });
    }

    get hasResults() {
        return this.candidates && this.candidates.length > 0;
    }

    toggleDetails(event) {
        const empId = event.currentTarget.dataset.employeeId;
        if (!empId) return;

        this.candidates = this.candidates.map(c => {
            if (c.employeeId !== empId) return c;

            const newShow = !c.showDetails;
            return {
                ...c,
                showDetails: newShow,
                detailsIcon: newShow ? 'utility:chevrondown' : 'utility:chevronright'
            };
        });
    }

    handleAssign(event) {
        const empId = event.target.dataset.employeeId;
        if (!empId) {
            this.showToast('Error', 'Employee Id missing from action.', 'error');
            return;
        }

        this.loading = true;

        createAssignment({ projectId: this.recordId, employeeId: empId })
            .then(() => {
                this.showToast('Success', 'Assignment created.', 'success');
            })
            .catch((err) => {
                this.showToast('Error', this.normalizeError(err), 'error');
            })
            .finally(() => {
                this.loading = false;
            });
    }

    showToast(title, message, variant = 'info') {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    normalizeError(err) {
        if (!err) return 'Unknown error';
        if (Array.isArray(err.body)) {
            return err.body.map(e => e.message).join(', ');
        }
        if (err.body && err.body.message) return err.body.message;
        if (err.message) return err.message;
        return JSON.stringify(err);
    }
}
