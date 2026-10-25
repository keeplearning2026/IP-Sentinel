"""Exercise the real installer functions without network access or root changes."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
TOKEN = "123456:TEST_SECRET_TOKEN"
OLD_TOKEN = "654321:OLD_SECRET_TOKEN"
NONCE = "installer_test_nonce"
PRIVATE_TEXT = "PRIVATE_MESSAGE_DO_NOT_LOG"
BASH = shutil.which("bash") or r"C:\Program Files\Git\bin\bash.exe"


def update(chat_id=10101, kind="private", sequence=1, text=None, name="Example"):
    message = {
        "chat": {"id": chat_id, "type": kind, "title": name},
        "from": {"id": 999999},
        "text": text if text is not None else f"/start {NONCE}",
    }
    return {
        "update_id": sequence,
        "channel_post" if kind == "channel" else "message": message,
    }


def response(result):
    return {"ok": True, "result": result}


def failure(code, description="API rejected request", **extra):
    return {"ok": False, "error_code": code, "description": description, **extra}


MOCK_CURL = r'''#!/bin/bash
set -euo pipefail
args=("$@")
output='' payload='' maximum=''
for ((i=0; i<${#args[@]}; i++)); do
    case "${args[$i]}" in
        -o) output=${args[$((i+1))]} ;;
        -d) payload=${args[$((i+1))]} ;;
        --max-time) maximum=${args[$((i+1))]} ;;
    esac
done
url=${args[$((${#args[@]}-1))]}
method=${url##*/}
printf '%s\t%s\t%s\n' "$method" "$payload" "$maximum" >> "$TG_TEST_DIR/requests"
directory="$TG_TEST_DIR/$method"
if [[ ! -f "$directory/total" ]]; then exit 7; fi
count=0
if [[ -f "$directory/count" ]]; then count=$(cat "$directory/count"); fi
count=$((count+1))
printf '%s' "$count" > "$directory/count"
total=$(cat "$directory/total")
if ((count > total)); then count=$total; fi
cp "$directory/$count.body" "$output"
cat "$directory/$count.http"
exit "$(cat "$directory/$count.exit")"
'''


class TelegramSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ips-telegram-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.config = self.directory / "config.conf"
        source = (ROOT / "install.sh").read_text(encoding="utf-8")
        functions = source.split("# BEGIN TELEGRAM_SETUP\n", 1)[1].split(
            "# END TELEGRAM_SETUP", 1
        )[0]
        self.write("functions.sh", functions)
        self.write("mock-curl.sh", MOCK_CURL)
        self.fixtures("getMe", response({"is_bot": True, "username": "example_bot"}))
        self.fixtures("getWebhookInfo", response({"url": ""}))
        self.fixtures("getUpdates", response([update()]))
        self.fixtures("sendMessage", response({"message_id": 1}))

    def write(self, filename, content):
        path = self.directory / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8", newline="\n")

    def fixtures(self, method, *entries):
        self.write(f"{method}/total", str(len(entries)))
        for number, entry in enumerate(entries, 1):
            body, http, status = entry if isinstance(entry, tuple) else (entry, 200, 0)
            self.write(
                f"{method}/{number}.body",
                body if isinstance(body, str) else json.dumps(body),
            )
            self.write(f"{method}/{number}.http", str(http))
            self.write(f"{method}/{number}.exit", str(status))

    def existing(self, token=TOKEN, chat_id="70707"):
        text = f'TG_TOKEN="{token}"\nTG_API_URL="https://api.telegram.org/bot{token}/sendMessage"\nCHAT_ID="{chat_id}"\n'
        self.write("config.conf", text)
        return text

    def run_setup(self, answers, *, success=True, scale=1, trace=False):
        script = r'''set -euo pipefail
SECURE_TMP="$TG_TEST_DIR"
CONFIG_FILE="$TG_TEST_DIR/config.conf"
source "$TG_TEST_DIR/functions.sh"
tg_nonce() { printf '%s' 'installer_test_nonce'; }
sleep() { SECONDS=$((SECONDS + $1 * TG_CLOCK_SCALE)); }
curl() { bash "$TG_TEST_DIR/mock-curl.sh" "$@"; }
SECONDS=0
configure_telegram
save_config_atomic <<EOF
TG_TOKEN="$TG_TOKEN"
TG_API_URL="$TG_API_URL"
CHAT_ID="$CHAT_ID"
EOF
jq -cn --arg token "$TG_TOKEN" --arg chat_id "$CHAT_ID" \
    --arg api "$TG_API_URL" --arg verified "$TG_SETUP_VERIFIED" \
    '{token: $token, chat_id: $chat_id, api: $api, verified: $verified}' > "$TG_TEST_DIR/result.json"
'''
        self.write("run.sh", script)
        completed = self.run_script("run.sh", answers, scale=scale, trace=trace)
        self.output = completed.stdout + completed.stderr
        self.assertNotIn(TOKEN, self.output)
        self.assertNotIn(OLD_TOKEN, self.output)
        self.assertNotIn(PRIVATE_TEXT, self.output)
        if success:
            self.assertEqual(completed.returncode, 0, self.output)
            self.result = json.loads((self.directory / "result.json").read_text())
        else:
            self.assertNotEqual(completed.returncode, 0, self.output)
            self.assertFalse((self.directory / "result.json").exists())
        return completed

    def run_script(self, name, answers="", *, scale=1, trace=False):
        environment = os.environ.copy()
        environment.update(
            TG_TEST_DIR=self.directory.as_posix(),
            TG_CLOCK_SCALE=str(scale),
            LANG="C.UTF-8",
        )
        completed = subprocess.run(
            [BASH, *(["-x"] if trace else []), (self.directory / name).as_posix()],
            # Binary stdin avoids Windows translating LF into CRLF for Bash read.
            input=answers.encode("utf-8"),
            capture_output=True,
            timeout=45,
            env=environment,
            cwd=ROOT,
        )
        completed.stdout = completed.stdout.decode("utf-8", errors="replace")
        completed.stderr = completed.stderr.decode("utf-8", errors="replace")
        return completed

    def requests(self, method=None):
        path = self.directory / "requests"
        lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
        result = []
        for line in lines:
            name, payload, maximum = line.split("\t")
            if method is None or name == method:
                result.append((name, json.loads(payload), int(maximum)))
        return result

    def test_single_private_chat_uses_chat_id_and_sends_before_saving(self):
        self.run_setup(f"{TOKEN}\n\n")
        self.assertEqual(self.result["chat_id"], "10101")
        self.assertEqual(self.result["verified"], "true")
        self.assertEqual(self.requests()[-1][0], "sendMessage")
        self.assertIsInstance(self.requests("sendMessage")[0][1]["chat_id"], str)
        self.assertEqual(self.result["api"], f"https://api.telegram.org/bot{TOKEN}/sendMessage")
        self.assertIn('CHAT_ID="10101"', self.config.read_text())
        if os.name != "nt":
            self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)

    def test_multiple_chats_require_explicit_valid_selection(self):
        self.fixtures("getUpdates", response([update(), update(20202, sequence=2)]))
        self.run_setup(f"{TOKEN}\n\n\nx\n2\n")
        self.assertEqual(self.result["chat_id"], "20202")
        self.assertIn("请选择列表中的有效序号", self.output)

    def test_duplicates_do_not_create_multiple_candidates(self):
        self.fixtures("getUpdates", response([update(), update(sequence=2)]))
        self.run_setup(f"{TOKEN}\n\n")
        self.assertEqual(self.result["chat_id"], "10101")
        self.assertIn("唯一会话", self.output)

    def test_full_page_is_drained_before_selecting(self):
        first_page = [update(sequence=i, text=PRIVATE_TEXT) for i in range(1, 100)]
        first_page.append(update(sequence=100))
        self.fixtures(
            "getUpdates", response(first_page), response([update(20202, sequence=101)])
        )
        self.run_setup(f"{TOKEN}\n\n2\n")
        self.assertEqual(self.result["chat_id"], "20202")
        self.assertEqual(self.requests("getUpdates")[1][1]["offset"], 101)
        self.assertTrue(all("allowed_updates" not in item[1] for item in self.requests()))

    def test_historical_single_chat_is_not_automatically_selected(self):
        self.fixtures(
            "getUpdates",
            response([update(90909, text=PRIVATE_TEXT, name="OLD_CHAT_DO_NOT_SELECT")]),
            response([]),
        )
        self.run_setup(f"{TOKEN}\n\nm\n80808\n", scale=30)
        self.assertEqual(self.result["chat_id"], "80808")
        self.assertNotIn("OLD_CHAT_DO_NOT_SELECT", self.output)
        self.assertIn("改为手动输入 Chat ID", self.output)

    def test_two_empty_detection_windows_then_manual(self):
        self.fixtures("getUpdates", response([]))
        self.run_setup(f"{TOKEN}\n\n\n30303\n", scale=30)
        self.assertEqual(self.result["chat_id"], "30303")
        self.assertIn("重试一次", self.output)
        self.assertEqual(len(self.requests("getUpdates")), 2)

    def test_webhook_falls_back_without_deleting_it(self):
        self.fixtures("getWebhookInfo", response({"url": "https://example.test/secret"}))
        self.run_setup(f"{TOKEN}\n-1001234567890\n")
        self.assertEqual(self.result["chat_id"], "-1001234567890")
        self.assertFalse(self.requests("getUpdates"))
        self.assertNotIn("secret", self.output)
        self.assertNotIn("deleteWebhook", [item[0] for item in self.requests()])

    def test_other_poller_conflict_falls_back(self):
        self.fixtures("getUpdates", (failure(409, "Conflict: another getUpdates"), 409, 0))
        self.run_setup(f"{TOKEN}\n\n40404\n")
        self.assertEqual(self.result["chat_id"], "40404")
        self.assertIn("其他轮询程序", self.output)

    def test_group_start_command_and_negative_id(self):
        self.fixtures("getUpdates", response([update(
            -1005556667778, "supergroup", text=f"/start@example_bot {NONCE}"
        )]))
        self.run_setup(f"{TOKEN}\n\n")
        self.assertEqual(self.result["chat_id"], "-1005556667778")
        self.assertIn("supergroup", self.output)

    def test_channel_post_is_detected(self):
        self.fixtures("getUpdates", response([update(-1007778889990, "channel")]))
        self.run_setup(f"{TOKEN}\n\n")
        self.assertEqual(self.result["chat_id"], "-1007778889990")

    def test_terminal_controls_are_removed_from_names(self):
        self.fixtures("getUpdates", response([update(name="Alice\n\x1b[31m\tSafe")]))
        self.run_setup(f"{TOKEN}\n\n")
        self.assertNotIn("\x1b", self.output)
        self.assertIn("Alice  [31m Safe", self.output)

    def test_invalid_token_has_three_attempts_and_preserves_config(self):
        original = self.existing(OLD_TOKEN)
        self.fixtures("getMe", (failure(401, "Unauthorized"), 401, 0))
        self.run_setup(f"{TOKEN}\n{TOKEN}\n{TOKEN}\n", success=False)
        self.assertEqual(len(self.requests("getMe")), 3)
        self.assertEqual(self.config.read_text(), original)
        self.assertFalse(self.requests("sendMessage"))

    def test_empty_and_malformed_tokens_never_call_api(self):
        self.run_setup("\nnot-a-token\n$(touch injected)\n", success=False)
        self.assertFalse(self.requests())
        self.assertFalse(self.config.exists())

    def test_network_failure_retries_without_using_invalid_token_attempt(self):
        self.fixtures("getMe", ("", "000", 7), response({"is_bot": True, "username": "example_bot"}))
        self.run_setup(f"{TOKEN}\n\n")
        self.assertEqual(len(self.requests("getMe")), 2)
        self.assertNotIn("Token 无效", self.output)

    def test_new_token_network_failure_cannot_be_saved(self):
        original = self.existing(OLD_TOKEN)
        self.fixtures("getMe", ("", "000", 7))
        self.run_setup(f"{TOKEN}\nq\n", success=False)
        self.assertEqual(len(self.requests("getMe")), 3)
        self.assertEqual(self.config.read_text(), original)

    def test_existing_config_can_be_kept_during_temporary_outage(self):
        self.existing(chat_id="-1001112223334")
        self.fixtures("getMe", ("", "000", 7))
        self.run_setup("\nk\n")
        self.assertEqual(self.result["chat_id"], "-1001112223334")
        self.assertEqual(self.result["verified"], "false")
        self.assertFalse(self.requests("sendMessage"))
        self.assertIn("日报可能发送失败", self.output)

    def test_enter_preserves_existing_target_without_discovery(self):
        original = self.existing(chat_id="-1001112223334")
        self.run_setup("\n\n")
        self.assertEqual(self.config.read_text(), original)
        self.assertFalse(self.requests("getUpdates"))
        self.assertFalse(self.requests("getWebhookInfo"))

    def test_reentering_same_token_does_not_change_target(self):
        self.existing(chat_id="@original_channel")
        self.run_setup(f"{TOKEN}\n\n")
        self.assertEqual(self.result["chat_id"], "@original_channel")
        self.assertFalse(self.requests("getUpdates"))

    def test_changed_token_rediscovers_instead_of_reusing_old_chat(self):
        self.existing(OLD_TOKEN, "70707")
        self.run_setup(f"{TOKEN}\n\n")
        self.assertEqual(self.result["chat_id"], "10101")
        self.assertEqual(self.result["token"], TOKEN)
        self.assertTrue(self.requests("getUpdates"))

    def test_same_token_can_explicitly_change_target(self):
        self.existing()
        self.run_setup("\nm\n-1003334445556\n")
        self.assertEqual(self.result["chat_id"], "-1003334445556")

    def test_manual_id_rejects_empty_and_shell_syntax(self):
        self.run_setup(f'{TOKEN}\nm\n\n$(touch injected)\n1+2\n-1001234567890\n')
        self.assertEqual(self.result["chat_id"], "-1001234567890")
        self.assertFalse((ROOT / "injected").exists())
        self.assertFalse(self.requests("getUpdates"))

    def test_failed_test_message_allows_manual_correction(self):
        self.fixtures("sendMessage", (failure(400, "Bad Request: chat not found"), 400, 0), response({"message_id": 2}))
        self.run_setup(f"{TOKEN}\n\nm\n50505\n")
        self.assertEqual(self.result["chat_id"], "50505")
        self.assertEqual([item[1]["chat_id"] for item in self.requests("sendMessage")], ["10101", "50505"])
        self.assertIn("chat not found", self.output)

    def test_failed_test_message_allows_reselection(self):
        self.fixtures("getUpdates", response([update(), update(20202, sequence=2)]))
        self.fixtures("sendMessage", (failure(403, "Forbidden: bot was blocked"), 403, 0), response({"message_id": 2}))
        self.run_setup(f"{TOKEN}\n\n1\ns\n2\n")
        self.assertEqual(self.result["chat_id"], "20202")

    def test_target_error_does_not_allow_save_and_continue(self):
        original = self.existing()
        self.fixtures("sendMessage", (failure(400, "chat not found"), 400, 0))
        self.run_setup("\n\nk\nq\n", success=False)
        self.assertEqual(self.config.read_text(), original)
        self.assertEqual(len(self.requests("sendMessage")), 1)

    def test_temporary_send_failure_requires_explicit_continue(self):
        self.fixtures("sendMessage", ("", "000", 7))
        self.run_setup(f"{TOKEN}\n\nk\n")
        self.assertEqual(len(self.requests("sendMessage")), 3)
        self.assertEqual(self.result["verified"], "false")
        self.assertIn("日报可能发送失败", self.output)

    def test_rate_limit_retries_and_respects_retry_after(self):
        self.fixtures("sendMessage", (failure(429, "Too Many Requests", parameters={"retry_after": 2}), 429, 0), response({"message_id": 2}))
        self.run_setup(f"{TOKEN}\n\n")
        self.assertEqual(len(self.requests("sendMessage")), 2)

    def test_large_retry_after_does_not_block_installer(self):
        self.fixtures("sendMessage", (failure(429, "Too Many Requests", parameters={"retry_after": 600}), 429, 0))
        self.run_setup(f"{TOKEN}\n\nk\n")
        self.assertEqual(len(self.requests("sendMessage")), 1)
        self.assertEqual(self.result["verified"], "false")

    def test_malformed_updates_response_falls_back(self):
        self.fixtures("getUpdates", ("<html>temporarily unavailable</html>", 502, 0))
        self.run_setup(f"{TOKEN}\n\n60606\n")
        self.assertEqual(self.result["chat_id"], "60606")
        self.assertNotIn("<html>", self.output)

    def test_error_summary_redacts_token_before_truncation(self):
        self.fixtures("sendMessage", (failure(400, "x" * 230 + TOKEN), 400, 0))
        self.run_setup(f"{TOKEN}\n\nq\n", success=False)
        self.assertNotIn("123456:", self.output)
        self.assertFalse(self.config.exists())

    def test_shell_trace_does_not_reveal_token(self):
        self.run_setup(f"{TOKEN}\n\n", trace=True)

    def test_eof_cancels_and_preserves_old_config(self):
        original = self.existing()
        self.run_setup("", success=False)
        self.assertEqual(self.config.read_text(), original)

    def test_atomic_publish_failure_leaves_original_intact(self):
        original = self.existing()
        self.write("atomic.sh", r'''set -euo pipefail
CONFIG_FILE="$TG_TEST_DIR/config.conf"
source "$TG_TEST_DIR/functions.sh"
mv() { return 1; }
save_config_atomic <<< 'replacement'
''')
        completed = self.run_script("atomic.sh")
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(self.config.read_text(), original)
        self.assertEqual(list(self.directory.glob("config.conf.*")), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
