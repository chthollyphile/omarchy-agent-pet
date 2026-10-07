import QtQuick
import Quickshell
import Quickshell.Io
import "lib/i18n.mjs" as I18n

// 无头调用 claude -p / codex exec 生成一句话。一次只跑一个请求。
// AGENT_PET_INTERNAL=1：agent-pet-hook 看到它直接退出，宠物自己的调用不会回灌成工作状态事件。
Scope {
  id: llm

  property string lang: "zh"
  property string home: ""
  property string stateDir: ""
  readonly property bool busy: proc.running
  property string lastUserText: ""
  // 调用方自定义标记（步骤总结用它记住是哪个会话）
  property string tag: ""

  property string petId: ""
  property string kind: ""
  property string meme: ""
  property bool timedOut: false

  // failed = true 时 text 是给用户看的失败原因
  signal finished(string petId, string kind, string text, string meme, bool failed)

  // cheap = 自动任务：Codex 额外压低推理强度
  function run(provider, model, systemPrompt, prompt, petId, kind, meme, cheap) {
    if (proc.running) return false
    var cmd
    if (provider === "codex") {
      cmd = ["codex", "exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "--color", "never"]
      if (model) cmd.push("-m", model)
      if (cheap) cmd.push("-c", "model_reasoning_effort=\"low\"")
      cmd.push(systemPrompt + "\n\n" + prompt)
    } else {
      // prompt 紧跟 -p：--tools 是变长参数，放在它后面会被当成工具名吃掉
      cmd = ["claude", "-p", prompt,
        "--system-prompt", systemPrompt,
        "--tools", "",
        "--setting-sources", "",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--no-session-persistence",
        "--output-format", "text"]
      if (model) cmd.push("--model", model)
    }
    llm.petId = petId
    llm.kind = kind
    llm.meme = meme || ""
    llm.timedOut = false
    proc.command = cmd
    proc.running = true
    timeout.restart()
    return true
  }

  // 对话要求模型回 {"text","meme"}；不守规矩时整段当文本
  function parseReply(raw) {
    var text = String(raw || "").trim()
    var m = text.match(/\{[\s\S]*\}/)
    if (m) {
      try {
        var obj = JSON.parse(m[0])
        if (obj && typeof obj.text === "string") return { text: obj.text.trim(), meme: String(obj.meme || "") }
      } catch (e) {}
    }
    return { text: text.replace(/^["“]|["”]$/g, ""), meme: "" }
  }

  Process {
    id: proc
    workingDirectory: llm.stateDir
    environment: ({ AGENT_PET_INTERNAL: "1" })
    stdout: StdioCollector { id: out }
    stderr: StdioCollector { id: err }

    onExited: function(exitCode) {
      timeout.stop()
      if (llm.timedOut) {
        llm.finished(llm.petId, llm.kind, I18n.t(llm.lang, "llmTimeout"), "", true)
        return
      }
      if (exitCode !== 0) {
        var reason = String(err.text || out.text || "").trim().split("\n").pop()
        llm.finished(llm.petId, llm.kind, I18n.t(llm.lang, "llmFailed", { reason: reason || I18n.t(llm.lang, "llmExitCode", { code: exitCode }) }), "", true)
        return
      }
      var reply = llm.parseReply(out.text)
      if (!reply.text) {
        llm.finished(llm.petId, llm.kind, I18n.t(llm.lang, "llmEmpty"), "", true)
        return
      }
      llm.finished(llm.petId, llm.kind, reply.text, llm.kind === "whisper" ? llm.meme : reply.meme, false)
    }
  }

  Timer {
    id: timeout
    interval: 90000
    onTriggered: {
      llm.timedOut = true
      proc.signal(15)
    }
  }
}
