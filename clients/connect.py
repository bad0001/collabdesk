#!/usr/bin/env python3
"""Verify the real Leader identity without publishing tasks or starting a model."""
import argparse
import json
import os
from pathlib import Path
from pull import pull
from transport import ClientError, endpoint, get_json


def connect(base, token, path, expected_member, expected_role, expected_workspace, save=False):
    status, data, _ = get_json(base, '/v1/snapshot', token)
    if status != 200:
        raise ClientError(f'Identity lookup returned HTTP {status}')
    if not isinstance(data, dict) or not isinstance(data.get('me'), dict):
        raise ClientError('Invalid identity lookup; checkpoint unchanged')
    me = data['me']
    if (me.get('id'), me.get('role'), data.get('workspaceId')) != (expected_member, expected_role, expected_workspace):
        raise ClientError('Identity or workspace mismatch; stop and check configuration')
    result = pull(base, token, path, dry_run=not save,
                  expected_member=expected_member, expected_workspace=expected_workspace)
    return {'ok': True, 'memberId': me['id'], 'role': me['role'],
            'name': me.get('name'), 'workspaceId': data['workspaceId'],
            'sync': result, 'pollingStarted': False}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base-url', required=True)
    p.add_argument('--expected-member', default='leader')
    p.add_argument('--expected-role', default='leader')
    p.add_argument('--expected-workspace', required=True)
    p.add_argument('--state', default='~/platform/collabdesk-leader/workspace.json')
    p.add_argument('--save', action='store_true', help='Save the verified incremental cache; does not mark tasks complete')
    p.add_argument('--allow-loopback', action='store_true')
    args = p.parse_args()
    try:
        base = endpoint(args.base_url, args.allow_loopback)
        token = os.environ.get('COLLAB_TOKEN', '')
        if not token:
            raise ClientError('Load COLLAB_TOKEN from your vault in a secret-capable agent context')
        result = connect(base, token, Path(args.state).expanduser(), args.expected_member,
                         args.expected_role, args.expected_workspace, args.save)
        print(json.dumps(result, ensure_ascii=False))
    except (ClientError, OSError) as error:
        print(json.dumps({'ok': False, 'error': str(error) if isinstance(error, ClientError) else 'Local checkpoint operation failed'}))
        raise SystemExit(2)


if __name__ == '__main__':
    main()
