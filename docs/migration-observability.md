# 인프라·컴퓨트 준비 결과 보고

인프라 PLAN/APPLY 실행기 자체는 이 저장소에 추가하지 않습니다. 실제 runner가 만든 job 결과와 `terraform show -json PLANFILE`을 요약해 컨트롤 플레인에 보고하는 도구를 제공합니다. Terraform 값·비밀 output·환경 파일·관리 주소는 전송하지 않습니다.

컨트롤 플레인에 workflow를 먼저 생성하고, job/handoff의 migration_id와 COMPUTE plan의 workflowId를 그 ID로 일치시킵니다. CP는 `CONTROL_PLANE_OBSERVATION_TOKEN_SECRET=env:OBSERVATION_TOKEN`을 설정합니다. 보고 프로세스에는 같은 토큰을 안전하게 주입합니다. workload 토큰을 재사용하지 않습니다.

```sh
python tools/report_observations.py --workflow "$WORKFLOW_ID" --control-plane "$CONTROL_PLANE_URL" \
  infra --job-json /run/jobs/apply-result.json --plan-json /run/jobs/plan.json --handoff-json /run/jobs/handoff.json
```

job JSON은 provisioning 계약의 id/migration_id/type/status에 **실제 시각** observed_at, requested_at, started_at, finished_at을 더합니다. SUCCEEDED에는 finished_at이 필수입니다. 기존 예제 job은 관측 시각이 없어서 제출되지 않습니다. 별도 runner는 job을 갱신한 뒤 이 도구를 호출해야 합니다. 변경 수는 plan의 resource_changes/actions에서 계산하며 replacement는 별도로 셉니다.

COMPUTE adapter를 배포한 뒤 다음처럼 읽기 전용 보고 프로세스를 실행합니다. COMPUTE_TOKEN은 adapter 인증값입니다. URL은 고정 운영 설정으로 제공하며 브라우저 입력으로 받지 않습니다.

```sh
python tools/report_observations.py --workflow "$WORKFLOW_ID" --control-plane "$CONTROL_PLANE_URL" \
  compute --adapter-url "$COMPUTE_ADAPTER_URL" --migration-id "$COMPUTE_MIGRATION_ID" --watch
```

`--watch`는 5초마다 조회합니다. 수집 실패 시 프로세스가 실패 종료하므로 서비스 관리자의 restart 정책과 오류 로그를 확인합니다. 이전 성공 시각을 새 시각으로 덮어쓰지 않아 CP에서 오래된 결과로 표시됩니다. --watch 없이 1회 보고도 가능합니다.

COMPUTE 작업에는 requestedAt/startedAt/finishedAt을 저장합니다. 기존 SQLite DB는 열을 추가해 호환합니다. 이미 저장된 작업의 시각은 null입니다. `details.compute`에는 최근 20개 명령 요약과 VM/이미지/설정/컨테이너·내부 검사 결과가 포함됩니다. 재시작으로 결과를 모르는 명령은 UNKNOWN이며, 종료 시각을 성공 시각처럼 만들어내지 않습니다.

START_SYNC 성공의 SYNCING/advance=UNKNOWN은 이 **준비 전용** 프로필의 정상 동작입니다. 이미지 원본 전달, 전체 앱 cutover, 실제 업무 health를 이 결과로 대신하지 않습니다.

검사: requirements-contracts.txt를 설치하고 `python -m unittest discover -s tests -v`.
