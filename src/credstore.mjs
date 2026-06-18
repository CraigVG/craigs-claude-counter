// macOS Keychain-backed credential store. One generic-password item per
// account, plus an "__index__" item holding the list of account ids.
// Tokens never touch disk in plaintext.
import { execFile } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { KEYCHAIN_SERVICE } from './config.mjs';

const INDEX_ACCOUNT = '__index__';

function run(args) {
  return new Promise((resolve, reject) => {
    execFile('security', args, { encoding: 'utf8' }, (err, stdout, stderr) => {
      if (err) {
        err.stderr = stderr;
        return reject(err);
      }
      resolve(stdout);
    });
  });
}

// Read one generic-password's secret (the -w form prints only the password).
async function readItem(service, account) {
  try {
    const out = await run(['find-generic-password', '-s', service, '-a', account, '-w']);
    return out.replace(/\n$/, '');
  } catch (err) {
    // 44 = item not found
    if (err.code === 44 || /could not be found/.test(err.stderr || '')) return null;
    throw err;
  }
}

// Upsert a generic-password. -U updates in place if it already exists.
async function writeItem(service, account, secret, label) {
  const args = ['add-generic-password', '-U', '-s', service, '-a', account, '-w', secret];
  if (label) args.push('-l', label);
  await run(args);
}

async function deleteItem(service, account) {
  try {
    await run(['delete-generic-password', '-s', service, '-a', account]);
  } catch (err) {
    if (err.code === 44 || /could not be found/.test(err.stderr || '')) return;
    throw err;
  }
}

async function readIndex(service) {
  const raw = await readItem(service, INDEX_ACCOUNT);
  if (!raw) return [];
  try {
    const arr = JSON.parse(raw);
    return Array.isArray(arr) ? arr : [];
  } catch {
    return [];
  }
}

async function writeIndex(service, ids) {
  await writeItem(service, INDEX_ACCOUNT, JSON.stringify(ids), 'claude-usage index');
}

export function newAccountId() {
  return 'acct_' + randomBytes(6).toString('hex');
}

export function createCredStore(service = KEYCHAIN_SERVICE) {
  return {
    service,

    async listAccounts() {
      const ids = await readIndex(service);
      const accounts = [];
      for (const id of ids) {
        const raw = await readItem(service, id);
        if (!raw) continue;
        try {
          accounts.push({ id, ...JSON.parse(raw) });
        } catch {
          /* skip corrupt item */
        }
      }
      return accounts;
    },

    async getAccount(id) {
      const raw = await readItem(service, id);
      if (!raw) return null;
      return { id, ...JSON.parse(raw) };
    },

    // Store/replace an account. `account` must include an `id`.
    async putAccount(account) {
      if (!account?.id) throw new Error('putAccount requires an id');
      const { id, ...rest } = account;
      await writeItem(service, id, JSON.stringify(rest), `claude-usage: ${rest.label || id}`);
      const ids = await readIndex(service);
      if (!ids.includes(id)) {
        ids.push(id);
        await writeIndex(service, ids);
      }
      return account;
    },

    async deleteAccount(id) {
      await deleteItem(service, id);
      const ids = (await readIndex(service)).filter((x) => x !== id);
      await writeIndex(service, ids);
    },

    // Test helper: wipe everything under this service.
    async _wipeAll() {
      const ids = await readIndex(service);
      for (const id of ids) await deleteItem(service, id);
      await deleteItem(service, INDEX_ACCOUNT);
    },
  };
}
