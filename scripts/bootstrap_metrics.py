"""Create bucket-scoped R2 credentials and seal them for the infra repository."""
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import urllib.error
import urllib.request
from nacl.public import PublicKey, SealedBox

account = os.environ['CLOUDFLARE_ACCOUNT_ID']
auth = os.environ['CLOUDFLARE_API_TOKEN']
recipient = SealedBox(PublicKey(base64.b64decode(os.environ['INFRA_PUBLIC_KEY'], validate=True)))
key_id = os.environ['INFRA_KEY_ID']
if not key_id:
    raise SystemExit('Missing infra repository public key ID')

def api(path, method='GET', payload=None):
    request = urllib.request.Request('https://api.cloudflare.com/client/v4' + path,
        data=json.dumps(payload).encode() if payload is not None else None, method=method,
        headers={'Authorization': 'Bearer ' + auth, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        raise SystemExit(f'Cloudflare {method} failed with HTTP {error.code}; no credentials printed') from None
    if not result.get('success'):
        raise SystemExit('Cloudflare operation failed; response withheld to protect credentials')
    return result['result']

prefix = f'/accounts/{account}/tokens'
groups = api(prefix + '/permission_groups')
permission = next(x['id'] for x in groups if x['name'] == 'Workers R2 Storage Bucket Item Write')
name = 'bitflip-metrics-events'
if any(x.get('name') == name for x in api(prefix)):
    raise SystemExit('Metrics token already exists. Recover the previous encrypted artifact instead of creating another token.')
created = api(prefix, 'POST', {'name': name, 'policies': [{'effect': 'allow',
    'permission_groups': [{'id': permission}],
    'resources': {f'com.cloudflare.edge.r2.bucket.{account}_default_bitflip-analytics-events': '*'}}]})
try:
    values = {
        'vault_metrics_r2_account_id': account,
        'vault_metrics_r2_access_key_id': created['id'],
        'vault_metrics_r2_secret_access_key': hashlib.sha256(created['value'].encode()).hexdigest(),
        'vault_metrics_admin_password': secrets.token_hex(32),
        'vault_metrics_hash_secret': secrets.token_hex(32),
    }
    sealed = base64.b64encode(recipient.encrypt(json.dumps(values).encode())).decode()
    Path('metrics-secret.sealed.json').write_text(json.dumps({'key_id': key_id, 'encrypted_value': sealed}))
except Exception:
    api(prefix + '/' + created['id'], 'DELETE')
    raise SystemExit('Credential sealing failed; newly created token revoked') from None
print('Created restricted metrics credentials; only repository-encrypted ciphertext will be uploaded.')
