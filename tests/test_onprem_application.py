"""The standalone IaC API prepares services, deploys the app, and retains its data."""

import copy
import json
import threading
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from test_node import executor, request
from test_node import node_config as node_config  # noqa: PLC0414 — shared pytest fixture
from test_onprem import FakeDriver, fixture
from test_provisioner import CATALOG, TOKEN, ReadyChecker

from provisioner.onprem import OnPremService
from provisioner.onprem_store import OnPremStore
from provisioner.server import ProvisionerServer
from provisioner.service import Service
from provisioner.store import Store


def test_prepare_deploy_protect_data_and_destroy_over_http(tmp_path, node_config):
    catalog, _, preparation = fixture(tmp_path)
    node_config["clouds"]["onprem"]["nodes"]["pc"]["preparation"] = {
        key: preparation[key] for key in ("target", "profileRef")
    }
    runner = executor(tmp_path, node_config)
    engine = Service(
        Store(tmp_path / "api.db"), runner, CATALOG, node_config, ReadyChecker()
    )
    prep = OnPremService(
        OnPremStore(tmp_path / "api.db"),
        catalog,
        FakeDriver(),
        engine.checker,
        app_store=engine.store,
    )
    engine.onprem = runner.preparations = prep
    server = ProvisionerServer(("127.0.0.1", 0), engine, TOKEN)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    def call(method, path, payload=None, key="test", authenticated=True):
        headers = {"Content-Type": "application/json", "Idempotency-Key": key}
        if authenticated:
            headers["Authorization"] = "Bearer " + TOKEN
        query = Request(
            f"http://127.0.0.1:{server.server_port}" + path,
            data=None if payload is None else json.dumps(payload).encode(),
            headers=headers,
            method=method,
        )
        try:
            response = urlopen(query, timeout=3)
        except HTTPError as error:
            response = error
        with response:
            return response.status, json.load(response)

    try:
        code, created = call(
            "POST", "/v2/environments", {**preparation, "mode": "apply"}
        )
        assert code == 202
        prep_id = created["environmentId"]
        payload = request(target={"nodeId": "pc", "preparationId": prep_id})
        code, _ = call("POST", "/v1/environments", payload, authenticated=False)
        assert code == 401
        code, _ = call("POST", "/v1/environments", payload)
        assert code == 400  # preparation must complete before app execution
        assert not runner.calls
        engine.run_next()
        assert prep.get(prep_id)["status"] == "INFRA_READY"
        wrong_owner = copy.deepcopy(payload)
        wrong_owner["org"]["id"] = "another-owner"
        assert call("POST", "/v1/environments", wrong_owner)[0] == 400
        code, created = call("POST", "/v1/environments", payload)
        assert code == 202
        app_path = "/v1/environments/" + created["environmentId"]
        assert call("POST", "/v1/environments", payload)[1] == created
        while engine.run_next():
            pass
        code, app = call("GET", app_path)
        assert code == 200 and app["status"] == "READY"
        assert app["handoff"]["preparationEnvironmentId"] == prep_id
        assert app["handoff"]["resources"]["storage"]["kind"] == "seaweedfs"
        assert "private-value" not in json.dumps(app)
        cleanup = {
            "expectedRevision": prep.get(prep_id)["revision"],
            "intent": "cleanup",
        }
        code, blocked = call(
            "POST", f"/v2/environments/{prep_id}/plan", cleanup, key="cleanup"
        )
        assert code == 409 and blocked["code"] == "PREPARATION_IN_USE"
        assert call("POST", app_path + "/reconcile", {})[0] == 202
        while engine.run_next():
            pass
        assert call("DELETE", app_path)[0] == 202
        while engine.run_next():
            pass
        assert call("GET", app_path)[1]["status"] == "DESTROYED"
        assert prep.get(prep_id)["status"] == "INFRA_READY"
        assert (
            call("POST", f"/v2/environments/{prep_id}/plan", cleanup, key="cleanup")[0]
            == 202
        )
    finally:
        server.shutdown()
        server.server_close()
        thread.join(3)
        engine.store.db.close()
        prep.store.db.close()
