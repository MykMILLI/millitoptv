// Idempotently wires watch parties into the dashboard source tree.
// Usage: node patch-dashboard.mjs /path/to/millitop-tv-dashboard
// Exits non-zero (without writing anything) if an anchor is missing.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const root = process.argv[2];
if (!root || !existsSync(join(root, 'server/index.mjs'))) {
  console.error('patch: dashboard directory not found');
  process.exit(2);
}

const edits = [];
function plan(file, transform) {
  const path = join(root, file);
  const before = readFileSync(path, 'utf8');
  const after = transform(before);
  if (after !== before) edits.push({ path, after });
}
function insertBefore(text, anchor, insert, label) {
  const index = text.indexOf(anchor);
  if (index < 0) throw new Error(`anchor not found for ${label}: ${anchor}`);
  return text.slice(0, index) + insert + text.slice(index);
}

try {
  plan('server/index.mjs', text => {
    let out = text;
    if (!out.includes("from './watch-party-routes.mjs'")) {
      out = `import { registerWatchPartyRoutes } from './watch-party-routes.mjs';\n` + out;
    }
    if (!/registerWatchPartyRoutes\(app/.test(out)) {
      out = insertBefore(out, "app.use('/downloads'",
        "registerWatchPartyRoutes(app, pool, { publicOrigin: process.env.PUBLIC_ORIGIN ?? 'https://tvadmin.millitop.net' });\n\n",
        'route registration');
    }
    return out;
  });

  plan('web/main.jsx', text => {
    let out = text;
    if (!out.includes("from './WatchPartyPanel.jsx'")) {
      out = `import WatchPartyPanel from './WatchPartyPanel.jsx';\n` + out;
    }
    if (!out.includes("['watchparty',")) {
      const match = /const navigation = \[(.*?)\];/s.exec(out);
      if (!match) throw new Error('anchor not found for navigation array');
      const replaced = match[0].replace(/\];$/, ",['watchparty','Watch parties']];");
      out = out.replace(match[0], replaced);
    }
    if (!out.includes("page==='watchparty'")) {
      const anchor = /\{page===['"]releases['"]&&<ReleasesPanel[^\n]*\n/.exec(out);
      if (!anchor) throw new Error('anchor not found for releases page line');
      out = out.replace(anchor[0], anchor[0] + "      {page==='watchparty'&&<WatchPartyPanel request={request} token={token}/>}\n");
    }
    return out;
  });

  if (existsSync(join(root, 'Dockerfile'))) {
    plan('Dockerfile', text => {
      if (text.includes('watch-party-routes.test.mjs')) return text;
      return insertBefore(text, 'RUN npm prune --omit=dev',
        'RUN node --check server/watch-party-routes.mjs && node --check server/watch-party-relay.mjs && node --check server/watch-party-web/watch.js && node --test server/watch-party-routes.test.mjs\n',
        'Dockerfile check line');
    });
  }
} catch (error) {
  console.error(`patch: ${error.message}`);
  process.exit(3);
}

for (const edit of edits) writeFileSync(edit.path, edit.after);
console.log(edits.length ? `patch: updated ${edits.map(e => e.path.slice(root.length + 1)).join(', ')}` : 'patch: already up to date');
