from fastapi.testclient import TestClient
from creator_worker.main import app

client = TestClient(app)
JOB_ID = "11111111-1111-4111-8111-111111111111"
ARTIFACT_ID = "22222222-2222-4222-8222-222222222222"


def request_body() -> dict[str, str]:
    return {
        "job_id": JOB_ID,
        "input_artifact_id": ARTIFACT_ID,
        "input_path": "private/projects/source.txt",
        "artifact_kind": "voice",
    }


def test_health_is_explicitly_mock_in_demo(monkeypatch) -> None:
    monkeypatch.setenv("CREATOR_RUNTIME_MODE", "demo")
    monkeypatch.setenv("CREATOR_PROVIDER_MODE", "mock")
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "runtime_mode": "demo",
        "provider_mode": "mock",
        "ready": True,
    }


def test_execute_fails_without_worker_token(monkeypatch) -> None:
    monkeypatch.delenv("CREATOR_WORKER_TOKEN", raising=False)
    response = client.post("/v1/jobs/execute", json=request_body())
    assert response.status_code == 401


def test_mock_generation_is_deterministic_and_labelled(monkeypatch) -> None:
    monkeypatch.setenv("CREATOR_RUNTIME_MODE", "test")
    monkeypatch.setenv("CREATOR_PROVIDER_MODE", "mock")
    monkeypatch.setenv("CREATOR_WORKER_TOKEN", "test-secret")
    first = client.post("/v1/jobs/execute", headers={"x-worker-token": "test-secret"}, json=request_body())
    second = client.post("/v1/jobs/execute", headers={"x-worker-token": "test-secret"}, json=request_body())
    assert first.status_code == 200
    assert second.status_code == 200
    assert first.json()["artifact"] == second.json()["artifact"]
    assert first.json()["artifact"]["is_mock"] is True
    assert first.json()["warning"].startswith("synthetic_mock")


def test_mock_generation_is_blocked_in_preview(monkeypatch) -> None:
    monkeypatch.setenv("CREATOR_RUNTIME_MODE", "preview")
    monkeypatch.setenv("CREATOR_PROVIDER_MODE", "mock")
    monkeypatch.setenv("CREATOR_WORKER_TOKEN", "test-secret")
    response = client.post("/v1/jobs/execute", headers={"x-worker-token": "test-secret"}, json=request_body())
    assert response.status_code == 503


def test_path_traversal_and_public_urls_are_rejected(monkeypatch) -> None:
    monkeypatch.setenv("CREATOR_WORKER_TOKEN", "test-secret")
    traversal = request_body()
    traversal["input_path"] = "private/../secret"
    public_url = request_body()
    public_url["input_path"] = "https://example.com/sample.wav"
    assert client.post("/v1/jobs/execute", headers={"x-worker-token": "test-secret"}, json=traversal).status_code == 422
    assert client.post("/v1/jobs/execute", headers={"x-worker-token": "test-secret"}, json=public_url).status_code == 422
