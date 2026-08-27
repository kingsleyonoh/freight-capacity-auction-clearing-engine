(function () {
  'use strict';

  const key = () => sessionStorage.getItem('fca_api_key') || '';
  const headers = () => ({ 'X-API-Key': key(), Accept: 'application/json' });
  const json = async (path, options) => {
    const response = await fetch(path, Object.assign({ headers: headers() }, options || {}));
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error((body.error && body.error.message) || 'Request failed');
    return body;
  };
  const text = (node, value) => { if (node) node.textContent = value == null ? '—' : String(value); };
  const rows = value => Array.isArray(value) ? value : (value && Array.isArray(value.data) ? value.data : []);
  const button = (label, handler) => {
    const item = document.createElement('button');
    item.className = 'row-action touch'; item.type = 'button'; item.textContent = label; item.addEventListener('click', handler); return item;
  };
  const fail = error => {
    document.querySelectorAll('[role="status"]').forEach(node => { if (node.textContent && /Loading|Awaiting/.test(node.textContent)) node.textContent = 'Offline or permission denied. Mutations remain disabled.'; });
    console.warn('fca-ui', error);
  };

  async function dashboard() {
    const [auctions, jobs, approvals] = await Promise.all([json('/api/auctions'), json('/api/clearing-jobs'), json('/api/approvals')]);
    text(document.querySelector('#open-auctions'), rows(auctions).filter(item => item.status === 'open').length);
    const kpis = document.querySelectorAll('.kpi');
    if (kpis[1]) text(kpis[1], rows(jobs).filter(item => ['queued', 'running'].includes(item.status)).length);
    if (kpis[2]) text(kpis[2], rows(approvals).filter(item => item.status === 'pending').length);
  }

  async function auctionList() {
    const state = document.querySelector('#auction-state'); const body = document.querySelector('#auction-table tbody');
    const search = document.querySelector('#auction-search'); const status = document.querySelector('#auction-status');
    const render = async () => {
      body.replaceChildren(); const query = new URLSearchParams(); if (search.value) query.set('search', search.value); if (status.value) query.set('status', status.value);
      const items = rows(await json('/api/auctions?' + query.toString()));
      items.forEach(item => { const tr = document.createElement('tr'); [['name', item.name], ['mode', item.mode], ['status', item.status], ['bid_close_at', item.bid_close_at]].forEach(([_, value]) => { const td = document.createElement('td'); td.textContent = value || '—'; tr.appendChild(td); }); const td = document.createElement('td'); const link = document.createElement('a'); link.className = 'row-action touch'; link.href = '/auctions/' + encodeURIComponent(item.id); link.textContent = 'Open'; td.appendChild(link); tr.appendChild(td); body.appendChild(tr); });
      text(state, items.length + ' auctions loaded.'); const empty = document.querySelector('#auction-empty'); if (empty) empty.hidden = items.length !== 0;
    };
    search.addEventListener('input', () => render().catch(fail)); status.addEventListener('change', () => render().catch(fail)); await render();
  }

  async function auctionDetail() {
    const match = location.pathname.match(/^\/auctions\/([^/]+)$/); if (!match || match[1] === 'new') return;
    const id = decodeURIComponent(match[1]); const auction = await json('/api/auctions/' + id); const bidRows = document.querySelector('table tbody');
    if (bidRows) { bidRows.replaceChildren(); rows(auction.bids).forEach(bid => { const tr = document.createElement('tr'); [bid.load_id, bid.equipment_type || '—', bid.status, bid.carrier_id || '—'].forEach(value => { const td = document.createElement('td'); td.textContent = value; tr.appendChild(td); }); bidRows.appendChild(tr); }); }
    const status = document.querySelector('.hero p:not(.eyebrow)'); if (status) status.textContent = 'Status: ' + (auction.status || 'unknown') + '. Loads and bids are tenant-scoped.';
    const action = async path => { const response = await json('/api/auctions/' + id + path, { method: 'POST', headers: Object.assign(headers(), { 'Content-Type': 'application/json' }), body: '{}' }); text(document.querySelector('.hero'), 'Action accepted: ' + (response.status || response.job_id || 'updated')); };
    const close = document.querySelector('#close-bidding'); if (close) close.addEventListener('click', () => action('/close-bidding').catch(fail));
    const clear = document.querySelector('#clear-auction'); if (clear) clear.addEventListener('click', () => action('/clear').catch(fail));
  }

  const mutation = (path, body) => json(path, { method: 'POST', headers: Object.assign(headers(), { 'Content-Type': 'application/json' }), body: JSON.stringify(body || {}) });

  async function importWizard() {
    const preview = document.querySelector('#import-preview'); const commit = document.querySelector('#import-commit');
    if (!preview) return;
    const live = document.querySelector('#import-live'); const data = document.querySelector('#import-data'); const resource = document.querySelector('#import-resource'); const filename = document.querySelector('#file-name');
    let importId = null;
    preview.addEventListener('click', async () => {
      try {
        const match = location.pathname.match(/^\/auctions\/([^/]+)\/import$/);
        const payload = { resource_type: resource.value, source_filename: filename.value || 'upload.csv', source_format: 'csv', csv: data.value || '', mapping: {} };
        if (match) payload.auction_id = decodeURIComponent(match[1]);
        const result = await json('/api/imports', { method: 'POST', headers: Object.assign(headers(), { 'Content-Type': 'application/json' }), body: JSON.stringify(payload) });
        importId = result.id; text(live, 'Preview ' + result.status + ': ' + result.valid_row_count + ' valid, ' + result.invalid_row_count + ' invalid.');
        if (commit) commit.disabled = result.invalid_row_count > 0 || !importId;
      } catch (error) { text(live, error.message); fail(error); }
    });
    if (commit) commit.addEventListener('click', async () => {
      if (!importId) return;
      try { const result = await mutation('/api/imports/' + encodeURIComponent(importId) + '/commit', { confirm: true }); text(live, 'Committed ' + (result.valid_row_count || 0) + ' rows.'); commit.disabled = true; } catch (error) { text(live, error.message); fail(error); }
    });
  }

  async function clearing() {
    const match = location.pathname.match(/^\/auctions\/([^/]+)\/clearing$/); if (!match) return;
    const id = decodeURIComponent(match[1]); const status = document.querySelector('.notice[role="status"]');
    try {
      const awards = rows(await json('/api/auctions/' + encodeURIComponent(id) + '/awards'));
      text(status, awards.length + ' award(s) loaded. Approval-required awards stay blocked from export.');
      const exportButton = document.querySelector('#export-awards');
      if (exportButton) exportButton.addEventListener('click', async () => { try { await mutation('/api/auctions/' + encodeURIComponent(id) + '/export', { format: 'json' }); text(status, 'Export ready.'); } catch (error) { text(status, error.message); fail(error); } });
    } catch (error) { text(status, 'Unable to load clearing evidence.'); fail(error); }
  }

  async function approvals() {
    const table = document.querySelector('table tbody'); if (!table) return; const items = rows(await json('/api/approvals')); table.replaceChildren();
    items.forEach(item => { const tr = document.createElement('tr'); [item.auction_id, item.reason, item.status].forEach(value => { const td = document.createElement('td'); td.textContent = value || '—'; tr.appendChild(td); }); const td = document.createElement('td'); if (item.award_id && item.status === 'pending') { td.appendChild(button('Approve', () => json('/api/awards/' + item.award_id + '/approve', { method: 'POST', headers: Object.assign(headers(), { 'Content-Type': 'application/json' }), body: JSON.stringify({ note: 'Approved in console' }) }).then(() => location.reload()).catch(fail))); td.appendChild(button('Reject', () => json('/api/awards/' + item.award_id + '/reject', { method: 'POST', headers: Object.assign(headers(), { 'Content-Type': 'application/json' }), body: JSON.stringify({ reason: 'Rejected in console' }) }).then(() => location.reload()).catch(fail))); } else td.textContent = 'Read-only'; tr.appendChild(td); table.appendChild(tr); });
  }

  async function replays() {
    const table = document.querySelector('#replay-table tbody'); if (!table) return;
    const render = async () => { const items = rows(await json('/api/replays')); table.replaceChildren(); items.forEach(item => { const tr = document.createElement('tr'); [item.name, item.baseline_strategy, item.status, item.dataset_uri].forEach(value => { const td = document.createElement('td'); td.textContent = value || '—'; tr.appendChild(td); }); const td = document.createElement('td'); if (['queued', 'running'].includes(item.status)) td.appendChild(button('Cancel', () => mutation('/api/replays/' + encodeURIComponent(item.id) + '/cancel').then(render).catch(fail))); else td.textContent = 'Read-only'; tr.appendChild(td); table.appendChild(tr); }); };
    await render();
    const queue = document.querySelector('#queue-replay'); if (queue) queue.addEventListener('click', async () => { try { const dataset = document.querySelector('#dataset').value; if (!dataset) throw new Error('A dataset path is required.'); const policies = rows(await json('/api/policies')); const policy = policies.find(item => item.status === 'active') || policies[0]; if (!policy) throw new Error('An active policy is required.'); await json('/api/replays', { method: 'POST', headers: Object.assign(headers(), { 'Content-Type': 'application/json' }), body: JSON.stringify({ name: 'Console replay', dataset_uri: dataset, baseline_strategy: document.querySelector('#baseline').value, policy_id: policy.id }) }); await render(); } catch (error) { fail(error); } });
  }

  async function notifications() {
    const list = document.querySelector('#notification-stream'); if (!list) return; const items = rows(await json('/api/notifications')); list.replaceChildren(); items.forEach(item => { const li = document.createElement('li'); li.className = 'status-list'; li.textContent = item.event_type + ' · ' + item.urgency + ' · ' + item.status; if (item.id && item.status !== 'read') li.appendChild(button('Mark read', () => json('/api/notifications/' + item.id + '/read', { method: 'POST' }).then(() => notifications()).catch(fail))); list.appendChild(li); });
  }

  async function integrations() {
    const table = document.querySelector('#integration-table tbody'); if (!table) return; const items = rows(await json('/api/integration-settings')); table.replaceChildren(); items.forEach(item => { const tr = document.createElement('tr'); [item.integration_name, item.enabled ? 'enabled' : 'disabled', item.last_health_status].forEach(value => { const td = document.createElement('td'); td.textContent = value; tr.appendChild(td); }); const td = document.createElement('td'); td.appendChild(button(item.enabled ? 'Disable' : 'Enable', () => json('/api/integration-settings', { method: 'PATCH', headers: Object.assign(headers(), { 'Content-Type': 'application/json' }), body: JSON.stringify({ integration_name: item.integration_name, enabled: !item.enabled, config: {} }) }).then(integrations).catch(fail))); tr.appendChild(td); table.appendChild(tr); });
  }

  async function notificationPreferences() {
    const form = document.querySelector('#notification-form'); const list = document.querySelector('#notification-stream'); if (!form && !list) return;
    if (list) await notifications();
    if (!form) return;
    const save = form.querySelector('#notification-save'); if (!save) return;
    save.addEventListener('click', async () => { try { const quiet = document.querySelector('#quiet-hours').value.trim(); const match = quiet.match(/^(\d{1,2}):00[–-](\d{1,2}):00$/); const quiet_hours = match ? { start_hour: Number(match[1]), end_hour: Number(match[2]) } : {}; for (const checkbox of form.querySelectorAll('input[data-event][data-channel]')) await json('/api/settings/notifications', { method: 'PATCH', headers: Object.assign(headers(), { 'Content-Type': 'application/json' }), body: JSON.stringify({ event_type: checkbox.dataset.event, channel: checkbox.dataset.channel, enabled: checkbox.checked, quiet_hours }) }); const status = document.createElement('p'); status.setAttribute('role', 'status'); status.textContent = 'Notification preferences saved.'; form.appendChild(status); } catch (error) { fail(error); } });
  }

  async function policies() {
    const list = document.querySelector('#policy-list'); const form = document.querySelector('#policy-form'); if (!list && !form) return;
    const render = async () => { const items = rows(await json('/api/policies')); if (list) { list.replaceChildren(); items.forEach(item => { const li = document.createElement('li'); li.textContent = item.name + ' v' + item.version + ' · ' + item.status; list.appendChild(li); }); } return items; };
    let items = await render();
    if (form) {
      const live = document.querySelector('#policy-live'); const payload = () => ({ name: document.querySelector('#policy-name').value, max_service_risk: document.querySelector('#service-risk').value, max_single_carrier_share: document.querySelector('#carrier-share').value, reserve_price_behavior: document.querySelector('#reserve-behavior').value });
      const save = document.querySelector('#policy-save'); if (save) save.addEventListener('click', async () => { try { await json('/api/policies', { method: 'POST', headers: Object.assign(headers(), { 'Content-Type': 'application/json' }), body: JSON.stringify(payload()) }); text(live, 'Draft saved.'); items = await render(); } catch (error) { text(live, error.message); fail(error); } });
      const activate = document.querySelector('#policy-activate'); if (activate) activate.addEventListener('click', async () => { try { const draft = items.find(item => item.status === 'draft'); if (!draft) throw new Error('Save a draft before activation.'); await mutation('/api/policies/' + encodeURIComponent(draft.id) + '/activate'); text(live, 'Policy activated.'); items = await render(); } catch (error) { text(live, error.message); fail(error); } });
    }
  }

  const path = location.pathname;
  Promise.resolve().then(() => path === '/dashboard' ? dashboard() : path === '/auctions' ? auctionList() : path === '/approvals' ? approvals() : path === '/replays' ? replays() : path === '/policies' || path.startsWith('/policies/') ? policies() : path === '/settings/notifications' ? notificationPreferences() : path === '/settings/integrations' ? integrations() : path.startsWith('/auctions/') && path.endsWith('/import') ? importWizard() : path.startsWith('/auctions/') && path.endsWith('/clearing') ? clearing() : path.startsWith('/auctions/') && !path.endsWith('/infeasible') ? auctionDetail() : Promise.resolve()).catch(fail);
}());
