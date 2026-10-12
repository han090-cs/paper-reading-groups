// Scheduled server-side backup. Credentials are read only from GitHub Actions secrets.
// Each PDF is stored as its own object in the private backup bucket; the manifest lists those objects.
const env = (key) => process.env[key] || '';
const need = (key) => env(key) || (console.error(`Secret ${key} မရှိပါ`), process.exit(1));
const baseUrl = need('SUPABASE_URL').replace(/\/$/, '');
// Prefer the current secret API key. The legacy service_role JWT remains supported during migration.
const secretKey = env('SUPABASE_SECRET_KEY');
const serviceKey = secretKey || need('SUPABASE_SERVICE_ROLE_KEY');
const headers = { apikey: serviceKey, ...(secretKey ? {} : { Authorization: `Bearer ${serviceKey}` }) };
const keepCount = Math.max(1, Number(env('BACKUP_KEEP') || 14));
const tableNames = ['profiles','groups','group_members','papers','reading_progress','research_notes','discussions','legacy_members'];
const bucketObjectLimit = 50 * 1024 * 1024;

function apiUrl(path) { return `${baseUrl}${path}`; }
async function request(path, options = {}) {
  const response = await fetch(apiUrl(path), { ...options, headers: { ...headers, ...(options.headers || {}) } });
  if (!response.ok) {
    const body = await response.text().catch(() => '');
    throw new Error(`Supabase request failed (${response.status}) for ${path}: ${body.slice(0, 300)}`);
  }
  return response;
}
async function getTable(table) {
  const out = [];
  for (let offset = 0; ; offset += 1000) {
    const response = await request(`/rest/v1/${table}?select=*&limit=1000&offset=${offset}`);
    const page = await response.json(); out.push(...page);
    if (page.length < 1000) break;
  }
  return out;
}
function safeStoragePath(path) { return path.split('/').map(encodeURIComponent).join('/'); }
async function deleteStored(path) {
  await request(`/storage/v1/object/backups-private/${safeStoragePath(path)}`, { method: 'DELETE' });
}
async function uploadObject(path, body, contentType) {
  const response = await request(`/storage/v1/object/backups-private/${safeStoragePath(path)}`, {
    method: 'POST', headers: { 'Content-Type': contentType, 'x-upsert': 'false' }, body,
  });
  return response;
}

const tables = {};
for (const table of tableNames) tables[table] = await getTable(table);
const admins = (tables.profiles || []).filter(profile => profile.role === 'admin');
if (!admins.length) throw new Error('Admin profile မရှိပါ — first admin setup လုပ်ပြီးမှ automatic backup ကို run ပါ');
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const runId = crypto.randomUUID();
const runPrefix = `scheduled/${stamp}-${runId}`;
const files = [];
let pdfBytes = 0;
const uploadedObjects = [];
let backupRecorded = false;
try {
  for (const paper of tables.papers || []) {
    if (!paper.pdf_path) continue;
    const sourcePath = `/storage/v1/object/authenticated/papers-private/${safeStoragePath(paper.pdf_path)}`;
    const response = await request(sourcePath);
    const bytes = Buffer.from(await response.arrayBuffer());
    if (bytes.byteLength > bucketObjectLimit) throw new Error(`PDF object ${paper.id} exceeds the private backup bucket's 50 MB per-object limit.`);
    const backupPath = `${runPrefix}/pdfs/${String(files.length + 1).padStart(4, '0')}.pdf`;
    await uploadObject(backupPath, bytes, 'application/pdf');
    uploadedObjects.push(backupPath);
    pdfBytes += bytes.byteLength;
    files.push({ path: paper.pdf_path, backupPath, contentType: 'application/pdf', size: bytes.byteLength });
  }
  const bundle = {
    format: 'paper-reading-groups-backup-v1',
    backupMode: 'split-private-storage',
    createdAt: new Date().toISOString(),
    projectUrl: baseUrl,
    tables,
    files,
  };
  const manifest = Buffer.from(JSON.stringify(bundle));
  if (manifest.byteLength > bucketObjectLimit) throw new Error('Backup manifest exceeds 50 MB; reduce table data or use Supabase CLI database exports.');
  const manifestPath = `${runPrefix}/manifest.json`;
  await uploadObject(manifestPath, manifest, 'application/json');
  uploadedObjects.push(manifestPath);
  const totalBytes = manifest.byteLength + pdfBytes;
  const details = {
    format: bundle.format,
    backupMode: bundle.backupMode,
    files: files.length,
    pdfBytes,
    rows: Object.fromEntries(Object.entries(tables).map(([key, value]) => [key, value.length])),
  };
  await request('/rest/v1/backup_runs', {
    method: 'POST', headers: { 'Content-Type': 'application/json', Prefer: 'return=minimal' },
    body: JSON.stringify({ created_by: admins[0].id, storage_path: manifestPath, backup_bytes: totalBytes, details }),
  });
  backupRecorded = true;
  console.log(`Backup saved privately: ${manifestPath}; bundle ${totalBytes} bytes; PDF bytes ${pdfBytes}; ${files.length} files.`);

  // Retain the newest N scheduled backups. Manual backups are not pruned by this job.
  const backups = await (await request('/rest/v1/backup_runs?select=id,storage_path,created_at&order=created_at.desc')).json();
  const scheduled = backups.filter(item => item.storage_path.startsWith('scheduled/'));
  for (const old of scheduled.slice(keepCount)) {
    try {
      const response = await request(`/storage/v1/object/authenticated/backups-private/${safeStoragePath(old.storage_path)}`);
      const oldBundle = await response.json();
      for (const file of oldBundle.files || []) {
        if (file.backupPath && file.backupPath.startsWith('scheduled/')) await deleteStored(file.backupPath);
      }
    } catch (error) {
      console.error(`Warning: could not fully enumerate files for old backup ${old.storage_path}: ${error.message}`);
    }
    await deleteStored(old.storage_path);
    await request(`/rest/v1/backup_runs?id=eq.${encodeURIComponent(old.id)}`, { method: 'DELETE' });
    console.log(`Pruned old scheduled backup: ${old.storage_path}`);
  }
} catch (error) {
  // Clean partial files only when this run never made it into the backup index.
  if (!backupRecorded) {
    for (const path of uploadedObjects) {
      try { await deleteStored(path); } catch { /* retain original error */ }
    }
  }
  throw error;
}
