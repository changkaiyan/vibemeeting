import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from services.stt_worker.stt_worker.config import load_config


class LoadConfigTests(unittest.TestCase):
    def test_load_config_reads_stt_worker_values_from_repo_env_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo_root = Path(temp_dir)
            env_path = repo_root / ".env"
            env_path.write_text(
                "\n".join(
                    [
                        "STT_WORKER_PROVIDER=faster_whisper",
                        "STT_WORKER_MODEL_SIZE=tiny",
                        "STT_WORKER_COMPUTE_TYPE=int8",
                        "",
                    ]
                ),
                encoding="utf-8",
            )

            with patch.dict(
                os.environ,
                {},
                clear=True,
            ):
                with patch(
                    "services.stt_worker.stt_worker.config._repo_root",
                    return_value=repo_root,
                ):
                    config = load_config()

        self.assertEqual(config.provider, "faster_whisper")
        self.assertEqual(config.model_size, "tiny")
        self.assertEqual(config.compute_type, "int8")
