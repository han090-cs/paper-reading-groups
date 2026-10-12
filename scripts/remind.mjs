// Server-side deadline reminder job. All credentials must be repository Actions secrets.
// Prefer the current secret API key; use legacy service_role JWT only as a migration fallback.
const env = (key) => process.env[key] || '';
const need = (key) => env(key) || (console.error(`Secret ${key} မရှိပါ`), process.exit(1));
const supabaseUrl = need('SUPABASE_URL').replace(/\/$/, '');
const secretKey = env('SUPABASE_SECRET_KEY');
const serviceKey = secretKey || need('SUPABASE_SERVICE_ROLE_KEY');
const force = env('FORCE') === '1';
const dryRun = env('DRY_RUN') === '1';
const baseHeaders = { apikey: serviceKey, ...(secretKey ? {} : { Authorization: `Bearer ${serviceKey}` }), Accept: 'application/json' };

async function getRows(table, query = 'select=*') {
  const response = await fetch(`${supabaseUrl}/rest/v1/${table}?${query}`, { headers: baseHeaders });
  if (!response.ok) {
    const body = await response.text().catch(() => '');
    throw new Error(`Supabase ${table} query failed (${response.status}): ${body.slice(0, 250)}`);
  }
  return response.json();
}
const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Yangon', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date());
const today = `${parts.find(p => p.type === 'year').value}-${parts.find(p => p.type === 'month').value}-${parts.find(p => p.type === 'day').value}`;
const [groups, papers, memberships, profiles] = await Promise.all([
  getRows('groups'),
  getRows('papers', `select=*&deadline=gte.${today}&order=deadline.asc`),
  getRows('group_members'),
  getRows('profiles', 'select=id,display_name,role'),
]);
const groupById = new Map(groups.map((group) => [group.id, group]));
const profileById = new Map(profiles.map((profile) => [profile.id, profile]));
const membersByGroup = new Map();
for (const member of memberships) {
  const name = profileById.get(member.user_id)?.display_name;
  if (!name) continue;
  const list = membersByGroup.get(member.group_id) || [];
  list.push(name);
  membersByGroup.set(member.group_id, list);
}
const site = env('SITE_URL') || `https://${(env('GITHUB_REPOSITORY') || '/').split('/')[0].toLowerCase()}.github.io/${(env('GITHUB_REPOSITORY') || '/').split('/')[1] || ''}/`;
const fmt = (date) => new Date(`${date}T12:00:00+06:30`).toLocaleString('en-GB', { timeZone: 'Asia/Yangon', dateStyle: 'medium' });
const messages = [];
for (const paper of papers) {
  if (!paper.deadline) continue;
  const group = groupById.get(paper.group_id);
  if (!group) continue;
  const hours = (new Date(`${paper.deadline}T23:59:59+06:30`) - Date.now()) / 36e5;
  if (hours <= 0) continue;
  const when = hours <= 24 ? '၂၄ နာရီအတွင်း ကျရောက်ပါမယ်' : hours <= 48 ? '၂ ရက်အတွင်း ကျရောက်ပါမယ်' : force ? `${Math.floor(hours / 24)} ရက်ကျန်ပါသေးတယ်` : '';
  if (!when) continue;
  const names = membersByGroup.get(group.id) || [];
  messages.push([
    `⏰ ${group.name} — Deadline ${when}`,
    `📄 ${paper.title}`,
    paper.source_url ? `🔗 ${paper.source_url}` : '',
    `🗓 ${fmt(paper.deadline)} (မြန်မာစံတော်ချိန်)`,
    `👥 Members:\n${names.map((name, index) => `${index + 1}. ${name}`).join('\n') || '-'}`,
    `🌐 ${site}`,
  ].filter(Boolean).join('\n'));
}
if (!messages.length) {
  console.log('ပို့စရာ reminder မရှိပါ');
  process.exit(0);
}
const telegramToken = dryRun ? env('TELEGRAM_BOT_TOKEN') : need('TELEGRAM_BOT_TOKEN');
const chatId = dryRun ? env('TELEGRAM_CHAT_ID') : need('TELEGRAM_CHAT_ID');
for (const message of messages) {
  if (dryRun) {
    console.log(`---\n${message}`);
    continue;
  }
  const response = await fetch(`https://api.telegram.org/bot${telegramToken}/sendMessage`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, text: message, disable_web_page_preview: true }),
  });
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    console.error('Telegram error:', body.description || response.status);
    process.exit(1);
  }
}
console.log(`Reminder ပို့ပြီး: ${messages.length} စောင်`);
