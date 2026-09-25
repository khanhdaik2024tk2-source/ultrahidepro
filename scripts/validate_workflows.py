"""scripts/validate_workflows.py — quick static check of GitHub Actions
YAML files (no extra dependency beyond PyYAML)."""
import sys
import yaml

EXPECTED = {
    '.github/workflows/build.yml': {
        'jobs': {'verify', 'lint'},
        'runner': 'macos-14',
        'arch': ['arm64'],
    },
    '.github/workflows/lint.yml': {
        'jobs': {'plist_json', 'sources_count', 'shellcheck'},
        'runner': 'ubuntu-22.04',
    },
}

ok = True
for path, exp in EXPECTED.items():
    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = yaml.safe_load(f)
    except FileNotFoundError:
        print(f"[!] missing: {path}")
        ok = False
        continue
    except yaml.YAMLError as e:
        print(f"[!] yaml parse error in {path}: {e}")
        ok = False
        continue

    jobs = set(data.get('jobs', {}).keys())
    missing = exp['jobs'] - jobs
    if missing:
        print(f"[!] {path}: missing jobs {missing}")
        ok = False
        continue

    if 'runner' in exp:
        runner_ok = False
        for j in exp['jobs']:
            if data['jobs'][j].get('runs-on') == exp['runner']:
                runner_ok = True
                break
        if not runner_ok:
            print(f"[!] {path}: no job uses runner {exp['runner']!r}")
            ok = False
            continue

    if 'arch' in exp:
        for j in exp['jobs']:
            cfg = data['jobs'][j]
            arch = cfg.get('strategy', {}).get('matrix', {}).get('arch')
            if arch is not None and arch != exp['arch']:
                print(f"[!] {path}.{j}: arch={arch} != {exp['arch']}")
                ok = False
                continue

    n_steps = sum(len(j.get('steps', [])) for j in data['jobs'].values())
    print(f"[OK] {path}: jobs={sorted(jobs)} steps={n_steps}")

if not ok:
    sys.exit(1)
print("All workflows OK")
