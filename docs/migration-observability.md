# IaC·COMPUTE OTEL 설정

`provisioner/service.py`와 `compute/adapter.py`는 실제 실행을 span으로 기록하고, 별도 5초 observer와 작업 완료 시점에 INFRA/COMPUTE snapshot을 발행합니다. 긴 apply 중에도 수집은 계속됩니다. `workflowId`는 CP에 등록한 workflow와 일치해야 합니다.

```sh
python -m pip install -r requirements-contracts.txt -r requirements-observability.txt
python -m control_plane.deployment.tools.report_observations --workflow "$WORKFLOW_ID" \
  infra --job-json /run/jobs/apply-result.json --plan-json /run/jobs/plan.json --handoff-json /run/jobs/handoff.json
```

별도 runner는 실제 job 시각을 제공해야 합니다. Terraform 변경 수만 요약하고 값·secret output·raw log는 전송하지 않습니다. API에서 저장한 응답은 `provisioner --environment-json ... --job-json ...`로 재발행할 수 있습니다. legacy COMPUTE 버전만 `compute --adapter-url ... --migration-id ... --watch` 보고기를 사용합니다. 새 adapter의 자체 발행과 동시에 실행하면 중복 표본이 생깁니다.

COMPUTE는 PREPARE/START_SYNC 준비 프로필입니다. SYNCING/advance=UNKNOWN을 전체 앱 cutover 완료로 해석하지 않습니다. `readiness.reporting.status=QUEUED_OTEL`은 SDK 큐에 넣었다는 뜻이며, CP 수신 완료 확인이 아닙니다. Collector/CP의 실제 수집 상태를 확인합니다.

## 수집 stack

1. `observability/.env.example`을 `.env`로 복사하고 서로 다른 module ingest token과 CP observation token, CP logs endpoint를 입력합니다.
2. `docker compose --env-file observability/.env -f observability/compose.yaml config -q`로 검사합니다.
3. `docker compose --env-file observability/.env -f observability/compose.yaml up -d`로 Collector/Prometheus/Tempo를 실행합니다. 최초 큐 volume 소유권은 전용 init container가 설정합니다.
4. CP에 동일한 observation token과 Prometheus/Tempo URL, 아래 SDK 환경을 주입합니다. 각 모듈은 module token을 사용합니다.

기본 port binding은 loopback입니다. 실제 앱/플랫폼 배포에서는 Collector의 bind 주소를 사설 NIC로 지정하고 해당 발행자 대역만 접근시킵니다. SDK endpoint는 발행 프로세스에서 도달 가능한 주소여야 합니다. 컨테이너의 localhost는 Collector가 아닙니다. Prometheus/Tempo는 CP가 조회할 수 있는 사설 경로로만 노출합니다.

logs는 file queue(256 batches), batch 최대 24개, 5분 재시도입니다. SDK 메모리 큐와 metrics/traces 큐는 유한하므로 장시간 장애/프로세스 강제 종료 중 관측 유실이 가능합니다. 제어 journal은 별도로 보존됩니다. raw snapshot은 DynamoDB, metrics/traces는 24시간 보존하며 원시 application log stack은 추가하지 않습니다. 공용 Cloudflare에는 Collector를 노출하지 않습니다.

## 기존 AWS 플랫폼 연결

`environments/platform/aws`의 선택 입력 `observability`에 endpoint, `headers_secret_arn`, prometheus_url, tempo_url을 설정합니다. DB backend·Redis migrator·Object·Traffic·Provisioner·CP task에 공통 SDK 환경/Secrets Manager 참조를 전달합니다. Collector stack은 관리 호스트에 위 compose로 별도 실행합니다. 새 입력은 null이면 비활성입니다. apply는 이 변경에서 실행하지 않습니다.

`headers_secret_arn`의 값은 `Authorization=Bearer%20<module-token>` 전체 문자열입니다. CP 수신 token은 기존 observation-token을 Collector에 주입합니다. 앱 VM/COMPUTE에는 cloud별 안전한 환경 주입 경로로 같은 SDK 설정을 전달합니다. 앱 배포의 `app.env`에는 endpoint/protocol만 두고 token은 secret 환경 파일에 주입합니다.

검사: `python -m unittest discover -s tests -v`, platform root의 `terraform init -backend=false`, `terraform validate`, `terraform test`. Compose의 실제 3-signal 검증은 CP `tests/integration/test_otel_stack.py`에 있습니다.

## OTEL 실행 설정

공식 OpenTelemetry SDK가 OTLP HTTP/protobuf로 로그·메트릭·트레이스를 내보냅니다. 아래 값을 **프로세스 환경**에 주입합니다. endpoint가 없거나 `OTEL_SDK_DISABLED=true`이면 전송하지 않습니다. `.env` 파일을 만드는 것만으로 Python 프로세스 환경이 바뀌지는 않습니다.

```dotenv
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.internal:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer%20<module-ingest-token>
```

Collector는 IaC의 `observability/compose.yaml`로 준비합니다. Collector → CP에는 별도 `OBSERVATION_TOKEN`을 씁니다. 모듈에 CP 수신 토큰을 주지 않습니다. 운영 주소는 사설망/VPN에서 접근하도록 구성하고, TLS를 사용하는 경우 SDK의 `OTEL_EXPORTER_OTLP_CERTIFICATE`와 HTTPS endpoint를 설정합니다. 앱 환경 값·DSN·Terraform output·원시 키·오류 원문은 전송하지 않습니다.

진행 상태는 OTEL 구조화 로그 → Collector → CP의 `OBS_LATEST`/24시간 이력, 수치는 Prometheus, 작업 span은 Tempo에 저장합니다. 플랫폼은 CP API만 조회합니다. 제어 명령·승인·멱등성·판정 근거는 기존 저장소가 원본이며 OTEL 전송 성공을 전환 조건으로 사용하지 않습니다. 관측이 끊겨도 이전 값을 0이나 성공으로 바꾸지 않습니다.

Python `telemetry.py`/`telemetry_contract.py`는 독립 이미지에 포함한 공통 계약 v1 사본입니다. 계약을 바꾸면 CP와 모든 Python 발행자의 사본 및 SDK 계약 테스트를 함께 갱신합니다. metric에는 operation/transition ID·키·URL을 label로 넣지 않으며, 값 캐시는 최대 2048 series/20초입니다. workflow ID는 마이그레이션별 화면 조회를 위한 제한된 차원입니다.
