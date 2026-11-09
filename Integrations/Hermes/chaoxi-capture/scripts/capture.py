#!/usr/bin/env python3
"""Capture, change or query Chaoxi items through the fixed app CLI."""
import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import uuid
from pathlib import Path

BINARY = str(Path.home() / "Applications" / "朝夕.app" / "Contents" / "MacOS" / "Chaoxi")
MESSAGE_KEYS = ("HERMES_SESSION_CHAT_ID", "HERMES_SESSION_MESSAGE_ID")
FIELDS = {"request_id", "title", "note", "date", "time", "duration_minutes", "source", "entry_index", "repeat_rule"}
CHANGE_FIELDS = {"request_id", "op", "target", "if_match", "fields", "occurrence_id", "new_date", "new_time", "from", "to", "entry_index"}
CHANGE_OPS = ("update", "delete", "restore", "reschedule_once", "complete", "reopen", "skip_once", "pause_range", "resume")
TARGET_KEYS = ("item_id", "occurrence_id", "capture_request_id")
CHANGE_DONE = {"updated", "deleted", "restored", "rescheduled", "skipped", "paused", "resumed", "completed", "reopened", "no_change", "already_processed"}
CLOCK = r"(?:[01][0-9]|2[0-3]):[0-5][0-9]"
ROW_OPTIONAL = ("revision", "note", "source", "capture_request_id", "feishu_readonly")


def _day(value):
    if not isinstance(value, str) or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value.strip()) is None:
        raise ValueError("date 必须为有效的 YYYY-MM-DD")
    try:
        datetime.date.fromisoformat(value.strip())
    except ValueError:
        raise ValueError("date 必须为有效的 YYYY-MM-DD") from None
    return value.strip()


def _request_id(payload, environment, kind="capture"):
    explicit = payload.get("request_id")
    if explicit is not None:
        if not isinstance(explicit, str) or not explicit.strip():
            raise ValueError("request_id 必须是非空字符串")
        if any(environment.get(key) and environment[key] in explicit for key in MESSAGE_KEYS):
            raise ValueError("request_id 不能包含原始消息标识")
        return explicit
    index = payload.get("entry_index", 0)
    if type(index) is not int or index < 0:
        raise ValueError("entry_index 必须是非负整数")
    chat, message = (environment.get(key) for key in MESSAGE_KEYS)
    if chat and message:
        basis = json.dumps([chat, message, kind, index], ensure_ascii=False, separators=(",", ":"))
        return "hermes:" + hashlib.sha256(basis.encode("utf-8")).hexdigest()
    return "hermes:" + str(uuid.uuid4())


def _redact(value, environment):
    if isinstance(value, str):
        for key in MESSAGE_KEYS:
            identifier = environment.get(key)
            if identifier:
                value = value.replace(identifier, "〈消息标识〉")
        return value
    if isinstance(value, dict):
        return {_redact(str(key), environment): _redact(item, environment) for key, item in value.items()}
    if isinstance(value, list):
        return [_redact(item, environment) for item in value]
    return value


def capture(payload, *, environment=None, runner=None, dry_run=False):
    """runner injection is the only test substitution; the executable is fixed."""
    environment = dict(os.environ if environment is None else environment)
    request_id = None

    def failed(status, error):
        return {"ok": False, "status": status, "request_id": request_id, "saved": False,
                "error": _redact(error, environment), "retry_same_id": request_id is not None}

    if not isinstance(payload, dict):
        return failed("invalid", "stdin 必须是 JSON 对象")
    try:
        request_id = _request_id(payload, environment)
        if set(payload) - FIELDS:
            raise ValueError("存在不支持的字段")
        index = payload.get("entry_index", 0)
        if type(index) is not int or index < 0:
            raise ValueError("entry_index 必须是非负整数")
        title = payload.get("title")
        if not isinstance(title, str) or not title.strip():
            raise ValueError("title 必须是非空字符串")
        for key in ("note", "date", "time"):
            if key in payload and not isinstance(payload[key], str):
                raise ValueError(key + " 必须是字符串")
        if "date" in payload:
            _day(payload["date"])
        if "time" in payload and re.fullmatch(r"(?:[01][0-9]|2[0-3]):[0-5][0-9]", payload["time"].strip()) is None:
            raise ValueError("time 必须为有效的 HH:mm")
        duration = payload.get("duration_minutes", 0)
        if type(duration) is not int or not 0 <= duration <= 1440:
            raise ValueError("duration_minutes 必须为 0 至 1440 的整数")
        if payload.get("time") and not payload.get("date"):
            raise ValueError("time 必须有明确 date")
        if duration and not payload.get("time"):
            raise ValueError("无时刻时 duration_minutes 只能为 0")
        repeat = payload.get("repeat_rule", "none")
        if repeat not in ("none", "daily", "weekdays", "weekly"):
            raise ValueError("repeat_rule 只能为 none、daily、weekdays 或 weekly")
        if repeat != "none" and not (payload.get("date") and payload.get("time")):
            raise ValueError("重复安排必须有明确 date 和 time")
        outgoing = {key: value for key, value in payload.items() if key != "entry_index"}
        outgoing.update(request_id=request_id, source="hermes")
        wire = json.dumps(outgoing, ensure_ascii=False, allow_nan=False)
    except (ValueError, TypeError) as error:
        return failed("invalid", str(error))

    argv = [BINARY, "--capture"] + (["--dry-run"] if dry_run else [])
    child_env = {key: value for key, value in environment.items() if key not in MESSAGE_KEYS}
    runner = subprocess.run if runner is None else runner
    try:
        process = runner(argv, input=wire, text=True, capture_output=True, timeout=30,
                         check=False, env=child_env)
    except subprocess.TimeoutExpired:
        return failed("timeout", "结果尚未确认；只用返回的 request_id 核对或重试，不换新编号")
    except OSError:
        return failed("unavailable", "朝夕调用未完成；保留 request_id，不报告已记下")
    except UnicodeError:
        return failed("malformed_response", "朝夕输出无法解码，保存结果尚未确认；保留 request_id")
    try:
        response = json.loads(process.stdout)
    except (TypeError, ValueError):
        return failed("malformed_response" if process.returncode == 0 else "process_failed", "朝夕未返回有效 JSON，保存结果尚未确认")
    if not isinstance(response, dict):
        return failed("malformed_response", "朝夕响应必须是 JSON 对象")
    if response.get("ok") is False:
        status = response.get("status")
        return failed(_redact(status, environment) if isinstance(status, str) else "capture_failed",
                      response.get("error", "朝夕未确认保存"))
    if process.returncode != 0:
        return failed("process_failed", "朝夕进程失败，保存结果尚未确认")
    if response.get("ok") is not True or response.get("request_id") != request_id:
        return failed("malformed_response", "朝夕成功响应或 request_id 不匹配，保存结果尚未确认")
    status = response.get("status")
    if dry_run:
        if status != "preview":
            return failed("malformed_response", "预览未返回 preview，不能当作保存")
        return {"ok": True, "status": "preview", "request_id": request_id, "saved": False}
    if status not in ("created", "already_processed") or type(response.get("item_exists")) is not bool:
        return failed("malformed_response", "朝夕响应缺少有效状态或事项存在信息")
    try:
        # Match the uppercase form that --query and --change return, so ids compare as plain strings.
        item_id = str(uuid.UUID(response["item_id"])).upper()
    except (KeyError, ValueError, TypeError, AttributeError):
        return failed("malformed_response", "朝夕响应缺少有效 item_id")
    exists = response["item_exists"]
    if status == "created" and not exists:
        return failed("malformed_response", "created 与 item_exists=false 冲突，不能报告创建成功")
    return {"ok": True, "status": status, "request_id": request_id, "item_id": item_id,
            "item_exists": exists, "saved": exists}


def change(payload, *, environment=None, runner=None, dry_run=False):
    """Change exactly one existing item through `Chaoxi --change`; never writes agenda.json."""
    environment = dict(os.environ if environment is None else environment)
    request_id = None

    def failed(status, error, response=None):
        result = {"ok": False, "status": status, "request_id": request_id, "saved": False,
                  "error": _redact(error, environment), "retry_same_id": request_id is not None}
        if isinstance(response, dict):
            for key in ("current", "item_id", "item_exists"):
                if key in response:
                    result[key] = _redact(response[key], environment)
        return result

    if not isinstance(payload, dict):
        return failed("invalid", "stdin 必须是 JSON 对象")
    try:
        if set(payload) - CHANGE_FIELDS:
            raise ValueError("存在不支持的字段：" + ", ".join(sorted(set(payload) - CHANGE_FIELDS)))
        request_id = _request_id(payload, environment, kind="change")
        if payload.get("op") not in CHANGE_OPS:
            raise ValueError("op 只能为 " + "、".join(CHANGE_OPS))
        target = payload.get("target")
        if not isinstance(target, dict) or len(target) != 1 or next(iter(target)) not in TARGET_KEYS or not isinstance(next(iter(target.values())), str):
            raise ValueError("target 必须只含 item_id、occurrence_id 或 capture_request_id 之一")
        key, value = next(iter(target.items()))
        if key == "item_id":
            uuid.UUID(value)
        elif key == "occurrence_id":
            _occurrence(value)
        if "occurrence_id" in payload:
            _occurrence(payload["occurrence_id"])
        for name in ("new_date", "from", "to"):
            if name in payload:
                _day(payload[name])
        if "new_time" in payload and (not isinstance(payload["new_time"], str) or re.fullmatch(CLOCK, payload["new_time"]) is None):
            raise ValueError("new_time 必须为有效的 HH:mm")
        if "if_match" in payload and not isinstance(payload["if_match"], str):
            raise ValueError("if_match 必须是查询返回的 revision 字符串")
        if "fields" in payload and not isinstance(payload["fields"], dict):
            raise ValueError("fields 必须是对象")
        if payload["op"] == "update" and not payload.get("fields"):
            raise ValueError("update 需要非空 fields")
        outgoing = {k: v for k, v in payload.items() if k != "entry_index"}
        outgoing.update(request_id=request_id, source="hermes")
        wire = json.dumps(outgoing, ensure_ascii=False, allow_nan=False)
    except (ValueError, TypeError, AttributeError) as error:
        return failed("invalid", str(error))

    argv = [BINARY, "--change"] + (["--dry-run"] if dry_run else [])
    child_env = {k: v for k, v in environment.items() if k not in MESSAGE_KEYS}
    runner = subprocess.run if runner is None else runner
    try:
        process = runner(argv, input=wire, text=True, capture_output=True, timeout=35, check=False, env=child_env)
    except subprocess.TimeoutExpired:
        return failed("timeout", "修改结果尚未确认；只用同一 request_id 核对或重试")
    except OSError:
        return failed("unavailable", "朝夕调用未完成；不能报告已修改")
    except UnicodeError:
        return failed("malformed_response", "朝夕输出无法解码，修改结果尚未确认")
    try:
        response = json.loads(process.stdout)
    except (TypeError, ValueError):
        return failed("malformed_response" if process.returncode == 0 else "process_failed", "朝夕未返回有效 JSON，修改结果尚未确认")
    if not isinstance(response, dict):
        return failed("malformed_response", "朝夕响应必须是 JSON 对象")
    if response.get("ok") is False:
        status = response.get("status")
        return failed(_redact(status, environment) if isinstance(status, str) else "change_failed",
                      response.get("error", "朝夕未确认修改"), response)
    if response.get("ok") is not True or response.get("request_id") != request_id or process.returncode != 0:
        return failed("malformed_response", "朝夕成功响应、进程状态或 request_id 不匹配，修改结果尚未确认")
    status = response.get("status")
    if dry_run:
        if status not in ("preview", "already_processed") or response.get("saved") is not False:
            return failed("malformed_response", "预览必须返回 preview 且 saved=false")
    elif status not in CHANGE_DONE or response.get("saved") is not True or type(response.get("item_exists")) is not bool:
        return failed("malformed_response", "朝夕响应缺少有效状态、saved 或 item_exists")
    result = {"ok": True, "status": status, "request_id": request_id, "saved": response.get("saved") is True,
              "item_exists": response.get("item_exists"), "item_id": response.get("item_id"),
              "before": response.get("before"), "after": response.get("after")}
    for key in ("expected_status", "message", "occurrence_id", "change_id"):
        if key in response:
            result[key] = response[key]
    if dry_run:
        result["saved"] = False
    return _redact(result, environment)


def _occurrence(value):
    if not isinstance(value, str) or ":" not in value:
        raise ValueError("occurrence_id 必须为 UUID:YYYY-MM-DD")
    item, day = value.split(":", 1)
    uuid.UUID(item)
    _day(day)
    return value


def _schedule_row(row, day):
    if not isinstance(row, dict) or not isinstance(row.get("title"), str) or not row["title"].strip():
        raise ValueError()
    item_id = str(uuid.UUID(row["id"]))
    occurrence_id = row.get("occurrence_id")
    if not isinstance(occurrence_id, str) or not occurrence_id.lower().startswith(item_id + ":"):
        raise ValueError()
    _day(occurrence_id[len(item_id) + 1:])
    if _day(row.get("date")) != day or row.get("repeat_rule") not in ("none", "daily", "weekdays", "weekly"):
        raise ValueError()
    for key in ("time", "base_time"):
        if key not in row or (row[key] is not None and (not isinstance(row[key], str) or re.fullmatch(CLOCK, row[key]) is None)):
            raise ValueError()
    # Query includes source events spanning multiple days; it does not create items.
    if type(row.get("duration_minutes")) is not int or not 0 <= row["duration_minutes"] <= 2**63 - 1 or type(row.get("completed")) is not bool or type(row.get("tentative")) is not bool:
        raise ValueError()
    keys = ("id", "occurrence_id", "title", "date", "time", "base_time", "duration_minutes", "repeat_rule", "completed", "tentative")
    return {key: row[key] for key in keys + tuple(k for k in ROW_OPTIONAL if k in row)}


def _skipped_rows(rows, day):
    if rows is None:
        return []
    if not isinstance(rows, list):
        raise ValueError()
    result = []
    for row in rows:
        if not isinstance(row, dict) or _day(row.get("date")) != day or row.get("skipped_by") not in ("skip_once", "pause_range"):
            raise ValueError()
        uuid.UUID(row["id"])
        result.append({key: row.get(key) for key in ("id", "occurrence_id", "title", "date", "base_time", "repeat_rule", "revision", "skipped_by", "paused_until")})
    return result


def query(payload, *, environment=None, runner=None):
    """Read a day and the checklist through the fixed app CLI; never capture."""
    environment = dict(os.environ if environment is None else environment)

    def failed(status, error):
        return {"ok": False, "status": _redact(status, environment), "read_only": True, "saved": False,
                "error": _redact(error, environment)}

    try:
        if not isinstance(payload, dict) or set(payload) - {"date", "from", "to"}:
            raise ValueError("查询 stdin 只能包含可选 date，或 from 与 to")
        if ("from" in payload) != ("to" in payload) or ("date" in payload and "from" in payload):
            raise ValueError("区间查询需同时提供 from 和 to，且不能与 date 混用")
        if "from" in payload:
            start, end = _day(payload["from"]), _day(payload["to"])
            span = (datetime.date.fromisoformat(end) - datetime.date.fromisoformat(start)).days
            if not 0 <= span < 31:
                raise ValueError("区间查询最多 31 天，且 from 不晚于 to")
            outgoing = {"from": start, "to": end}
        else:
            outgoing = {"date": _day(payload["date"])} if "date" in payload else {}
        wire = json.dumps(outgoing, ensure_ascii=False, allow_nan=False)
    except (ValueError, TypeError) as error:
        return failed("invalid", str(error))
    runner = subprocess.run if runner is None else runner
    child_env = {key: value for key, value in environment.items() if key not in MESSAGE_KEYS}
    try:
        process = runner([BINARY, "--query"], input=wire, text=True, capture_output=True,
                         timeout=30, check=False, env=child_env)
    except subprocess.TimeoutExpired:
        return failed("timeout", "查询未完成；不能据此判断没有事项")
    except OSError:
        return failed("unavailable", "朝夕查询不可用；不能据此判断没有事项")
    except UnicodeError:
        return failed("malformed_response", "查询结果无法解码")
    try:
        response = json.loads(process.stdout)
        if not isinstance(response, dict):
            raise ValueError()
        if response.get("ok") is False:
            status = response.get("status")
            return failed(status if isinstance(status, str) else "query_failed",
                          response.get("error", "朝夕未返回查询结果"))
        if process.returncode != 0:
            return failed("process_failed", "朝夕查询进程失败")
        if response.get("ok") is not True or response.get("status") != "queried" or response.get("read_only") is not True or response.get("timezone") != "Asia/Shanghai":
            raise ValueError()
        generated_at = response.get("generated_at")
        if not isinstance(generated_at, str):
            raise ValueError()
        generated = datetime.datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
        if generated.tzinfo is None:
            raise ValueError()
        checklist = response.get("checklist")
        if not isinstance(checklist, list):
            raise ValueError()
        checklist_rows = []
        for row in checklist:
            if not isinstance(row, dict) or not isinstance(row.get("title"), str) or not row["title"].strip() or type(row.get("completed")) is not bool:
                raise ValueError()
            uuid.UUID(row["id"])
            checklist_rows.append({key: row[key] for key in ("id", "title", "completed") + tuple(k for k in ROW_OPTIONAL if k in row)})
        base = {"ok": True, "status": "queried", "read_only": True, "saved": False,
                "timezone": "Asia/Shanghai", "generated_at": generated_at}
        if "from" in outgoing:
            days = response.get("days")
            if response.get("from") != outgoing["from"] or response.get("to") != outgoing["to"] or not isinstance(days, list):
                raise ValueError()
            expected = [(datetime.date.fromisoformat(outgoing["from"]) + datetime.timedelta(days=offset)).isoformat()
                        for offset in range((datetime.date.fromisoformat(outgoing["to"]) - datetime.date.fromisoformat(outgoing["from"])).days + 1)]
            if not all(isinstance(entry, dict) for entry in days) or [entry.get("date") for entry in days] != expected:
                raise ValueError()
            day_rows = []
            for entry in days:
                if not isinstance(entry.get("schedule"), list):
                    raise ValueError()
                day_rows.append({"date": entry["date"], "schedule": [_schedule_row(row, entry["date"]) for row in entry["schedule"]],
                                 "skipped": _skipped_rows(entry.get("skipped"), entry["date"])})
            return _redact(dict(base, **{"from": outgoing["from"], "to": outgoing["to"], "days": day_rows, "checklist": checklist_rows}), environment)
        day = _day(response.get("date"))
        if outgoing.get("date", day) != day:
            raise ValueError()
        schedule = response.get("schedule")
        if not isinstance(schedule, list):
            raise ValueError()
        return _redact(dict(base, date=day, schedule=[_schedule_row(row, day) for row in schedule],
                            skipped=_skipped_rows(response.get("skipped"), day), checklist=checklist_rows), environment)
    except (ValueError, TypeError, KeyError, AttributeError):
        return failed("malformed_response", "朝夕查询结果缺少有效日期、时刻或事项字段；不能当作空清单")


def main():
    parser = argparse.ArgumentParser(description="通过 stdin JSON 捕获、修改或只读查询朝夕事项")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--query", action="store_true", help="只读查询日程和清单，不保存")
    mode.add_argument("--change", action="store_true", help="修改、删除、恢复、跳过或完成一条已有事项")
    parser.add_argument("--dry-run", action="store_true", help="只预览，不保存（用于捕获或 --change）")
    arguments = parser.parse_args()
    if arguments.query and arguments.dry_run:
        parser.error("--query 本身只读，不接受 --dry-run")
    try:
        payload = json.load(sys.stdin)
    except (ValueError, UnicodeError):
        result = {"ok": False, "status": "invalid", "saved": False, "error": "stdin 不是有效 JSON"}
    else:
        if arguments.query:
            result = query(payload)
        elif arguments.change:
            result = change(payload, dry_run=arguments.dry_run)
        else:
            result = capture(payload, dry_run=arguments.dry_run)
    print(json.dumps(result, ensure_ascii=False, allow_nan=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
