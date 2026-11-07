# 기존 공용 앱의 시스템 메트릭 연결

기존 AWS·GCP 치이카와는 별도 프로비저너의 공용 배포입니다. `environments/platform/aws/seed.yaml`의 `systemDeployments`는 이 두 배포만 로그인 사용자에게 조회하도록 등록합니다. 프로비저너의 `id`, `deployment_id`, `org_id`, `cloud`를 확인한 뒤 등록합니다. 소유권 변경이나 SQLite 복사는 필요하지 않습니다.

| 환경 | environmentId | deploymentId | ownerId |
| --- | --- | --- | --- |
| aws | env-784e02b9c9d5 | chiikawa-aws-3e3d | chiikawa |
| gcp | env-4f5690bb766b | chiikawa-gcp-1975 | chiikawa |

등록한 앱의 **해당 배포** 메트릭만 공유됩니다. 개인 배포는 등록하지 않습니다. 앱이 교체되면 새 ID를 검증해 등록하고 이전 항목을 제거합니다. 온프렘도 실제 배포 ID와 시드의 환경을 등록하는 같은 방식입니다.

## 기존 앱 설정 생성

다음 명령은 비밀값 없는 환경 파일만 출력합니다. 배포하거나 DB를 수정하지 않습니다. API와 worker 각각 생성합니다.

```sh
python tools/render_system_metrics_env.py \
  --seed environments/platform/aws/seed.yaml \
  --environment-id env-784e02b9c9d5 \
  --endpoint https://<앱에서-접속할-collector>:4318 \
  --role api --network-scope container > /tmp/chiikawa-api-otel.env
```

GCP는 표의 GCP ID를 사용합니다. worker는 `--role worker`로 별도 파일을 만듭니다. VM·온프렘의 격리된 컨테이너는 `container`, Fargate·Cloud Run처럼 네트워크를 공유하는 앱 인스턴스는 `app-instance`를 지정합니다. 공유 모드에서는 API만 네트워크를 보고합니다. CPU·메모리·디스크 I/O는 항상 컨테이너 범위입니다. 서버 전체 파일시스템 용량은 수집하지 않습니다.

생성된 변수를 기존 컨테이너 설정에 추가하고 `OTEL_EXPORTER_OTLP_HEADERS`는 기존 Secret 경로로 주입합니다. 앱의 DB·Redis·Object 설정과 볼륨은 유지합니다. `service.instance.id`는 실행 시 생성되므로 고정하지 않습니다. Collector 주소는 앱의 사설망에서 접속 가능한 주소여야 하며, ECS 내부 DNS를 다른 VPC·GCP·온프렘에서 바로 쓸 수 있다고 가정하지 않습니다.

## 반영 순서와 확인

1. 공용 등록을 지원하는 최신 control-plane 이미지와 시드를 함께 반영합니다. 이전 이미지는 `systemDeployments` 필드를 거부합니다. 프론트엔드도 해당 버전으로 갱신합니다.
2. 최신 Collector/Prometheus 설정을 반영합니다. `observability/prometheus.yaml`의 application·owner·deployment·environment·instance·network scope 라벨을 보존해야 합니다.
3. 앱 컨테이너 메트릭 수집을 지원하는 demo 이미지를 사용하고 위 OTEL 변수를 API·worker에 적용합니다. 기존 배포를 새로 만들거나 DB를 초기화하지 않습니다. 프로비저너의 `appTelemetry` 수정만으로 기존 앱은 변경되지 않습니다.
4. 앱에서 Collector까지 OTLP 전송을 확인합니다. Prometheus의 `foxtrot_runtime_collection`에 표의 ID가 들어오고 값이 갱신되는지 확인합니다. 예전 `system_*`만 있으면 아직 새 수집 경로가 아닙니다.
5. 로그인 후 `/v1/applications/chiikawa/system-metrics/deployments`에 `shared:env-…`, `access: shared`로 대상이 보이는지 확인합니다. 마지막 수집이 30초를 넘으면 목록에서 빠집니다. 시스템 화면에서 두 배포를 바꿔 보며 API·worker별 CPU·메모리·디스크 I/O·네트워크와 최근 수집 시간을 확인합니다.

새 컨테이너에서 커널 지표를 제공하지 않으면 해당 값은 비어 있을 수 있습니다. 이를 서버 전체 수치나 0으로 채우지 않습니다. 마이그레이션 상태·로그·트레이스는 workflow 기준이며, 이 시스템 메트릭 설정만으로 마이그레이션 로그 API 배포가 완료되는 것은 아닙니다.
