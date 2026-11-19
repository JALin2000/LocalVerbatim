#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/localverbatim-engine-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/runtime/bin" "$scratch/engine" "$scratch/models/Qwen3-ASR-1.7B-bf16"
ln -s "${LOCALVERBATIM_TEST_PYTHON:-$project/runtime/bin/python}" "$scratch/runtime/bin/python"
echo '{}' > "$scratch/models/Qwen3-ASR-1.7B-bf16/config.json"
cat > "$scratch/engine/worker.py" <<'PY'
import json, sys, time, signal
print('{"type":"ready"}',flush=True)
for line in sys.stdin:
    job=json.loads(line)
    if job.get('command')=='shutdown':break
    if job['path']=='/slow-ignore-term':
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(5)
    time.sleep(0.05)
    if '/quality-' in job['id']:
        failed = '/quality-failure' in job['id']
        print(json.dumps({'type':'error' if failed else 'result','id':job['id'],'text':'Recovered actual speech','message':'quality retry failed','fatal':False,'quality':{'status':'failed' if failed else 'recovered','attempts':[{'text':'Okay. ' * 100}]}}),flush=True)
        continue
    if job['path']=='/force-error':
        print(json.dumps({'type':'error','id':job['id'],'message':'moved archive','fatal':False}),flush=True)
        continue
    print(json.dumps({'type':'result','id':job['id'],'text':'test','language':'','seconds':0.05}),flush=True)
PY
swiftc -swift-version 5 -target arm64-apple-macos15.0 -parse-as-library \
  -module-cache-path "${LOCALVERBATIM_TEST_MODULE_CACHE:-$scratch/modules}" \
  "$project/Sources/LocalVerbatim/AudioCapture.swift" "$project/Sources/LocalVerbatim/Models.swift" "$project/Sources/LocalVerbatim/MeetingFiles.swift" "$project/Sources/LocalVerbatim/FillerReducer.swift" \
  "$project/Sources/LocalVerbatim/AppSettings.swift" "$project/Sources/LocalVerbatim/AsyncTimeout.swift" \
  "$project/Sources/LocalVerbatim/TranscriptionEngine.swift" "$project/tests/test_engine.swift" -o "$scratch/check"
LOCALVERBATIM_ROOT="$scratch" "$scratch/check"
