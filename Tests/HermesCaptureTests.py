"""Fail-closed unit tests: no app, Hermes, network or message invocation."""
import importlib.util
import io
import json
import subprocess
import sys
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / "Integrations/Hermes/chaoxi-capture/scripts/capture.py"
spec = importlib.util.spec_from_file_location("chaoxi_hermes_capture", SCRIPT)
capture_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture_module)
ITEM_ID = "ddb5ed46-02c3-467e-9df6-c4939d687bd7"
ENV = {"HERMES_SESSION_CHAT_ID": "private-chat-12345", "HERMES_SESSION_MESSAGE_ID": "private-message-67890", "PATH": "/fake"}


class HermesCaptureTests(unittest.TestCase):
    def setUp(self):
        self.guard = mock.patch.object(subprocess, "run", side_effect=AssertionError("Real process launch is forbidden"))
        self.guard.start()
        self.addCleanup(self.guard.stop)
        self.calls = []

    def runner(self, *, update=None, stdout=None, returncode=0, error=None):
        def fake(argv, **kwargs):
            self.calls.append((argv, kwargs))
            if error is not None:
                raise error
            payload = json.loads(kwargs["input"])
            response = {"ok": True, "status": "created", "request_id": payload["request_id"],
                        "item_id": ITEM_ID, "item_exists": True}
            if update:
                response.update(update)
            return SimpleNamespace(returncode=returncode, stdout=stdout if stdout is not None else json.dumps(response), stderr="private diagnostic must not be copied")
        return fake

    def send(self, payload=None, **kwargs):
        return capture_module.capture({"title": "买充电线"} if payload is None else payload,
                                      environment=kwargs.pop("environment", ENV), runner=kwargs.pop("runner", self.runner()), **kwargs)

    def test_fixed_message_id_same_on_retry_and_private_ids_not_transmitted(self):
        first = self.send()
        second = self.send()
        self.assertEqual(first["request_id"], second["request_id"])
        self.assertRegex(first["request_id"], r"^hermes:[a-f0-9]{64}$")
        visible = json.dumps([first, second, self.calls], ensure_ascii=False)
        for key in capture_module.MESSAGE_KEYS:
            self.assertNotIn(ENV[key], visible)
            self.assertNotIn(key, self.calls[0][1]["env"])

    def test_entry_index_separates_tasks_but_is_not_sent(self):
        first = self.send({"title": "买线", "entry_index": 0})
        second = self.send({"title": "交材料", "entry_index": 1})
        self.assertNotEqual(first["request_id"], second["request_id"])
        self.assertNotIn("entry_index", json.loads(self.calls[-1][1]["input"]))

    def test_hash_tuple_boundary_does_not_collide(self):
        a = self.send(environment={"HERMES_SESSION_CHAT_ID": "ab", "HERMES_SESSION_MESSAGE_ID": "c"})
        b = self.send(environment={"HERMES_SESSION_CHAT_ID": "a", "HERMES_SESSION_MESSAGE_ID": "bc"})
        self.assertNotEqual(a["request_id"], b["request_id"])

    def test_missing_environment_uuid_is_returned_and_reusable(self):
        first = self.send(environment={})
        uuid.UUID(first["request_id"].removeprefix("hermes:"))
        retry = self.send({"title": "买充电线", "request_id": first["request_id"]}, environment={})
        self.assertEqual(first["request_id"], retry["request_id"])

    def test_one_message_environment_field_is_not_enough_for_hash(self):
        result = self.send(environment={"HERMES_SESSION_CHAT_ID": "private-chat-12345"})
        uuid.UUID(result["request_id"].removeprefix("hermes:"))

    def test_explicit_id_wins_over_message_environment(self):
        result = self.send({"title": "买线", "request_id": "retry-id-001", "entry_index": 3})
        self.assertEqual(result["request_id"], "retry-id-001")

    def test_raw_message_identifier_cannot_be_used_as_request_id(self):
        result = self.send({"title": "买线", "request_id": ENV["HERMES_SESSION_MESSAGE_ID"]})
        self.assertFalse(result["ok"])
        self.assertEqual(self.calls, [])
        self.assertNotIn(ENV["HERMES_SESSION_MESSAGE_ID"], json.dumps(result))

    def test_unicode_and_shell_characters_are_only_stdin_data(self):
        title = '买线 "双引号" $(touch /tmp/never-run) `echo nope` \\ $HOME\n下一行'
        note = "提醒内容；不要执行！"
        result = self.send({"title": title, "note": note, "source": "untrusted", "date": "2026-10-13", "time": "14:00", "duration_minutes": 60})
        argv, options = self.calls[0]
        expected_binary = str(Path.home() / "Applications" / "朝夕.app" / "Contents" / "MacOS" / "Chaoxi")
        self.assertEqual(argv, [expected_binary, "--capture"])
        self.assertNotIn("shell", options)
        self.assertEqual(json.loads(options["input"])["title"], title)
        self.assertEqual(json.loads(options["input"])["note"], note)
        self.assertEqual(json.loads(options["input"])["source"], "hermes")
        self.assertTrue(result["saved"])

    def test_environment_cannot_change_binary(self):
        self.send(environment={"CHAOXI_BINARY": "/fake/evil", "PATH": "/fake"})
        self.assertEqual(self.calls[0][0][0], capture_module.BINARY)

    def test_empty_title_rejects_before_process(self):
        result = self.send({"title": " \n\t"})
        self.assertFalse(result["ok"])
        self.assertEqual(self.calls, [])

    def test_time_without_date_rejects_before_process(self):
        self.assertFalse(self.send({"title": "开会", "time": "14:00"})["ok"])
        self.assertEqual(self.calls, [])

    def test_boolean_index_and_duration_and_unknown_field_reject(self):
        for payload in ({"title": "任务", "entry_index": True}, {"title": "任务", "duration_minutes": True},
                        {"title": "任务", "duration_minutes": 1441}, {"title": "任务", "executable": "/fake/evil"}):
            self.assertFalse(self.send(payload)["ok"])
        self.assertEqual(self.calls, [])

    def test_repeat_schedule_passes_explicit_date_time_duration_without_changing_id(self):
        payload = {"title": "复习", "date": "2026-10-13", "time": "09:00",
                   "duration_minutes": 30, "repeat_rule": "daily"}
        first = self.send(payload)
        retry = self.send(payload)
        self.assertEqual(first["request_id"], retry["request_id"])
        wire = json.loads(self.calls[0][1]["input"])
        self.assertEqual((wire["date"], wire["time"], wire["duration_minutes"], wire["repeat_rule"]),
                         ("2026-10-13", "09:00", 30, "daily"))
        self.assertTrue(first["saved"])
        self.send(dict(payload, repeat_rule="weekdays"))
        self.assertEqual(json.loads(self.calls[-1][1]["input"])["repeat_rule"], "weekdays")

    def test_repeat_without_date_or_time_and_unknown_repeat_fail_before_process(self):
        for payload in ({"title": "任务", "repeat_rule": "daily"},
                        {"title": "任务", "date": "2026-10-13", "repeat_rule": "weekdays"},
                        {"title": "任务", "date": "2026-10-13", "time": "09:00", "repeat_rule": "weekly"},
                        {"title": "任务", "repeat_rule": None}, {"title": "任务", "repeat_rule": True}):
            self.assertFalse(self.send(payload)["ok"])
        self.assertEqual(self.calls, [])

    def test_invalid_calendar_date_clock_and_untimed_duration_fail_before_process(self):
        for payload in ({"title": "任务", "date": "2026-02-30"},
                        {"title": "任务", "date": "0000-10-13"},
                        {"title": "任务", "date": "2026-1-01"},
                        {"title": "任务", "date": "２０２６-10-13"},
                        {"title": "任务", "date": "2026-10-13", "time": "24:00"},
                        {"title": "任务", "date": "2026-10-13", "time": "9:00"},
                        {"title": "任务", "duration_minutes": 30}):
            self.assertFalse(self.send(payload)["ok"])
        self.assertEqual(self.calls, [])

    def test_legacy_payload_omits_repeat_but_explicit_none_is_supported(self):
        first = self.send()
        self.assertNotIn("repeat_rule", json.loads(self.calls[0][1]["input"]))
        second = self.send({"title": "买充电线", "repeat_rule": "none"})
        self.assertEqual(first["request_id"], second["request_id"])
        self.assertEqual(json.loads(self.calls[-1][1]["input"])["repeat_rule"], "none")

    def query_response(self):
        return {"ok": True, "status": "queried", "read_only": True, "timezone": "Asia/Shanghai",
                "date": "2026-10-13", "generated_at": "2026-10-13T01:00:00Z",
                "schedule": [{"id": ITEM_ID, "occurrence_id": ITEM_ID + ":2026-10-12",
                              "title": "晨间安排", "date": "2026-10-13", "time": "09:15", "base_time": "09:00",
                              "duration_minutes": 0, "repeat_rule": "daily", "completed": False, "tentative": False}],
                "checklist": [{"id": ITEM_ID, "title": "买充电线", "completed": False}]}

    def query_runner(self, response=None, *, returncode=0, stdout=None, error=None):
        def fake(argv, **kwargs):
            self.calls.append((argv, kwargs))
            if error is not None:
                raise error
            return SimpleNamespace(returncode=returncode,
                                   stdout=stdout if stdout is not None else json.dumps(self.query_response() if response is None else response),
                                   stderr="private diagnostic must not be copied")
        return fake

    def read(self, payload=None, **kwargs):
        return capture_module.query({} if payload is None else payload, environment=ENV,
                                    runner=kwargs.pop("runner", self.query_runner()), **kwargs)

    def test_query_only_uses_fixed_read_only_cli_and_hides_message_environment(self):
        result = self.read()
        argv, options = self.calls[0]
        self.assertEqual(argv, [capture_module.BINARY, "--query"])
        self.assertEqual(json.loads(options["input"]), {})
        self.assertNotIn("shell", options)
        for key in capture_module.MESSAGE_KEYS:
            self.assertNotIn(key, options["env"])
        self.assertTrue(result["ok"])
        self.assertTrue(result["read_only"])
        self.assertFalse(result["saved"])
        self.assertNotIn("request_id", result)
        self.assertEqual((result["schedule"][0]["time"], result["schedule"][0]["base_time"]), ("09:15", "09:00"))
        self.assertEqual(result["schedule"][0]["occurrence_id"], ITEM_ID + ":2026-10-12")

    def test_query_date_and_untimed_rows_are_supported(self):
        response = self.query_response()
        response["schedule"][0].update(time=None, base_time=None, repeat_rule="none", completed=True, tentative=True)
        result = self.read({"date": " 2026-10-13 "}, runner=self.query_runner(response))
        self.assertTrue(result["ok"])
        self.assertEqual(json.loads(self.calls[0][1]["input"]), {"date": "2026-10-13"})
        self.assertIsNone(result["schedule"][0]["time"])
        self.assertTrue(result["schedule"][0]["completed"])

    def test_query_keeps_multiday_source_durations_but_capture_limit_stays_one_day(self):
        for duration in (0, 1440, 2880, 4320, 2**63 - 1):
            response = self.query_response(); response["schedule"][0]["duration_minutes"] = duration
            result = self.read(runner=self.query_runner(response))
            self.assertTrue(result["ok"])
            self.assertEqual(result["schedule"][0]["duration_minutes"], duration)
        self.calls.clear()
        self.assertFalse(self.send({"title": "不能捕获多日时长", "date": "2026-10-13", "time": "09:00", "duration_minutes": 2880})["ok"])
        self.assertEqual(self.calls, [])

    def test_query_rejects_negative_bool_noninteger_and_beyond_swift_int_duration(self):
        for duration in (-1, True, False, 2**63, 1.5, "2880", None):
            response = self.query_response(); response["schedule"][0]["duration_minutes"] = duration
            result = self.read(runner=self.query_runner(response))
            self.assertFalse(result["ok"])
            self.assertNotIn("schedule", result)

    def test_query_rejects_capture_fields_invalid_date_and_nonobject_before_process(self):
        for payload in ({"title": "买线"}, {"date": "2026-02-30"}, {"request_id": "new-item"}, [], {"date": None}):
            self.assertFalse(self.read(payload)["ok"])
        self.assertEqual(self.calls, [])

    def test_query_failure_is_never_successful_empty_checklist_or_capture(self):
        for runner in (self.query_runner({"ok": False, "status": "unavailable", "error": "不能读取"}, returncode=1),
                       self.query_runner(returncode=1), self.query_runner(stdout="not-json"),
                       self.query_runner(error=subprocess.TimeoutExpired("fake", 30)),
                       self.query_runner(error=FileNotFoundError("private detail"))):
            result = self.read(runner=runner)
            self.assertFalse(result["ok"])
            self.assertFalse(result["saved"])
            self.assertNotIn("checklist", result)
        self.assertTrue(all(call[0] == [capture_module.BINARY, "--query"] for call in self.calls))

    def test_query_malformed_contract_and_wrong_requested_date_fail_closed(self):
        for update in ({"read_only": False}, {"timezone": "UTC"}, {"status": "created"},
                       {"schedule": None}, {"checklist": {}}, {"generated_at": "2026-10-13T09:00:00"},
                       {"date": "2026-10-14"}):
            response = self.query_response(); response.update(update)
            self.assertFalse(self.read({"date": "2026-10-13"}, runner=self.query_runner(response))["ok"])
        for update in ({"id": "bad"}, {"occurrence_id": ITEM_ID + ":2026-02-30"},
                       {"base_time": "24:00"}, {"time": "9:00"}, {"duration_minutes": True},
                       {"completed": 0}, {"tentative": None}, {"repeat_rule": "weekly"}, {"date": "2026-10-14"}):
            response = self.query_response(); response["schedule"][0].update(update)
            self.assertFalse(self.read(runner=self.query_runner(response))["ok"])

    def test_query_error_redacts_ids_and_success_drops_unknown_diagnostics(self):
        response = self.query_response(); response["diagnostic"] = ENV["HERMES_SESSION_CHAT_ID"]
        result = self.read(runner=self.query_runner(response))
        self.assertNotIn("diagnostic", result)
        error = self.read(runner=self.query_runner({"ok": False, "status": ENV["HERMES_SESSION_CHAT_ID"], "error": ENV["HERMES_SESSION_MESSAGE_ID"]}))
        self.assertNotIn(ENV["HERMES_SESSION_MESSAGE_ID"], json.dumps(error))
        self.assertNotIn(ENV["HERMES_SESSION_CHAT_ID"], json.dumps(error))

    def test_no_query_runner_injection_cannot_launch_under_guard(self):
        with self.assertRaisesRegex(AssertionError, "Real process launch"):
            capture_module.query({}, environment={})

    def test_main_query_routes_only_to_query(self):
        output = io.StringIO()
        actual_query = capture_module.query
        def safe_query(payload):
            return actual_query(payload, environment=ENV, runner=self.query_runner())
        with mock.patch.object(sys, "argv", ["capture.py", "--query"]), mock.patch.object(sys, "stdin", io.StringIO("{}")), mock.patch.object(sys, "stdout", output), mock.patch.object(capture_module, "query", side_effect=safe_query), mock.patch.object(capture_module, "capture", side_effect=AssertionError("Query cannot capture")):
            code = capture_module.main()
        result = json.loads(output.getvalue())
        self.assertEqual(code, 0)
        self.assertEqual(result["status"], "queried")
        self.assertFalse(result["saved"])

    def test_malformed_response_is_never_success(self):
        for stdout in ("not-json", "[]", "null", '{"ok":true}'):
            self.assertFalse(self.send(runner=self.runner(stdout=stdout))["saved"])

    def test_nonzero_exit_with_success_json_is_failure(self):
        result = self.send(runner=self.runner(returncode=2))
        self.assertFalse(result["ok"])
        self.assertFalse(result["saved"])
        self.assertNotIn("private diagnostic", json.dumps(result))

    def test_error_status_and_error_are_preserved_even_with_nonzero_exit(self):
        for status in ("pending", "conflict", "invalid", "save_failed"):
            result = self.send(runner=self.runner(update={"ok": False, "status": status, "error": {"code": status, "message": "需要核对"}}, returncode=1))
            self.assertEqual(result["status"], status)
            self.assertEqual(result["error"]["code"], status)
            self.assertFalse(result["saved"])

    def test_error_private_identifiers_are_redacted(self):
        result = self.send(runner=self.runner(update={"ok": False, "status": "invalid", "error": {"message": ENV["HERMES_SESSION_CHAT_ID"], ENV["HERMES_SESSION_MESSAGE_ID"]: "bad"}}))
        for key in capture_module.MESSAGE_KEYS:
            self.assertNotIn(ENV[key], json.dumps(result))

    def test_timeout_retains_same_id_for_explicit_retry(self):
        timeout = subprocess.TimeoutExpired("fake", 30)
        first = self.send(environment={}, runner=self.runner(error=timeout))
        self.assertEqual(first["status"], "timeout")
        self.assertFalse(first["saved"])
        second = self.send({"title": "买充电线", "request_id": first["request_id"]}, environment={})
        self.assertEqual(first["request_id"], second["request_id"])

    def test_unavailable_is_never_success(self):
        result = self.send(runner=self.runner(error=FileNotFoundError("private detail")))
        self.assertEqual(result["status"], "unavailable")
        self.assertFalse(result["saved"])
        self.assertNotIn("private detail", json.dumps(result))

    def test_deleted_already_processed_does_not_claim_saved(self):
        result = self.send(runner=self.runner(update={"status": "already_processed", "item_exists": False}))
        self.assertTrue(result["ok"])
        self.assertFalse(result["saved"])
        self.assertFalse(result["item_exists"])

    def test_existing_already_processed_is_saved(self):
        result = self.send(runner=self.runner(update={"status": "already_processed"}))
        self.assertTrue(result["saved"])

    def test_mismatched_id_invalid_uuid_or_nonboolean_exists_fail_closed(self):
        for update in ({"request_id": "wrong-id"}, {"item_id": "not-uuid"}, {"item_exists": 1},
                       {"item_exists": False}, {"ok": 1}, {"status": "preview"}):
            self.assertFalse(self.send(runner=self.runner(update=update))["saved"])

    def test_dry_run_preview_is_not_saved(self):
        result = self.send(dry_run=True, runner=self.runner(update={"status": "preview"}))
        self.assertTrue(result["ok"])
        self.assertEqual(result["status"], "preview")
        self.assertFalse(result["saved"])
        self.assertEqual(self.calls[0][0], [capture_module.BINARY, "--capture", "--dry-run"])

    def test_dry_run_created_response_is_not_saved(self):
        result = self.send(dry_run=True)
        self.assertFalse(result["saved"])
        self.assertFalse(result["ok"])

    def test_no_runner_injection_cannot_launch_under_test_guard(self):
        with self.assertRaisesRegex(AssertionError, "Real process launch"):
            capture_module.capture({"title": "不可实际启动"}, environment={})

    def test_invalid_stdin_main_fails_before_any_runner(self):
        output = io.StringIO()
        with mock.patch.object(sys, "argv", ["capture.py"]), mock.patch.object(sys, "stdin", io.StringIO("bad json")), mock.patch.object(sys, "stdout", output):
            code = capture_module.main()
        result = json.loads(output.getvalue())
        self.assertEqual(code, 1)
        self.assertFalse(result["saved"])
        self.assertEqual(self.calls, [])

    def test_main_dry_run_stdin_and_stdout_remain_preview(self):
        output = io.StringIO()
        actual_capture = capture_module.capture
        fake_runner = self.runner(update={"status": "preview"})
        def safe_capture(payload, *, dry_run):
            return actual_capture(payload, environment=ENV, runner=fake_runner, dry_run=dry_run)
        with mock.patch.object(sys, "argv", ["capture.py", "--dry-run"]), mock.patch.object(sys, "stdin", io.StringIO('{"title":"交材料"}')), mock.patch.object(sys, "stdout", output), mock.patch.object(capture_module, "capture", side_effect=safe_capture):
            code = capture_module.main()
        result = json.loads(output.getvalue())
        self.assertEqual(code, 0)
        self.assertEqual(result["status"], "preview")
        self.assertFalse(result["saved"])

    def test_undecodable_output_preserves_id_without_raw_exception(self):
        error = UnicodeDecodeError("utf8", b"\xff", 0, 1, "private detail")
        result = self.send(runner=self.runner(error=error))
        self.assertEqual(result["status"], "malformed_response")
        self.assertFalse(result["saved"])
        self.assertNotIn("private detail", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
