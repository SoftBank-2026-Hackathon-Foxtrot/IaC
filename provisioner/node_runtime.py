"""Start the user app on a prepared node using its existing data services."""

from pathlib import Path


def onprem_entrypoint(port: int, api_workers: int) -> list[str]:
    startup = Path(__file__).with_name("onprem_start.py.tmpl").read_text()
    startup = startup.replace("${port}", str(port)).replace(
        "${api_workers}", str(api_workers)
    )
    return ["python", "-c", startup]
