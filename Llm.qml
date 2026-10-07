import QtQuick
import Quickshell
import Quickshell.Io
import "lib/i18n.mjs" as I18n

// 无头调用 claude -p / codex exec 生成一句话。一次只跑一个请求。
// AGENT_PET_INTERNAL=1：agent-pet-hook 看到它直接退出，宠物自己的调用不会回灌成工作状态事件。
// 提示词和对话历史不放进命令行参数（进程参数对本机所有用户可见）：
// 提示词走 stdin，Claude 的系统提示词写进 stateDir（0700）下的文件，用 --system-prompt-file 传路径。
Scope {
  id: llm

  // 区分多个实例的系统提示词文件
  property string name: "llm"
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
      // 不给 PROMPT 参数时 codex exec 从 stdin 读指令
      cmd = ["codex", "exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "--color", "never"]
      if (model) cmd.push("-m", model)
      if (cheap) cmd.push("-c", "model_reasoning_effort=\"low\"")
      proc.input = systemPrompt + "\n\n" + prompt
    } else {
      systemFile.setText(systemPrompt)
      // 不给 prompt 参数时 claude -p 从 stdin 读
      proc.input = prompt
      cmd = ["claude", "-p",
        "--system-prompt-file", systemFile.path,
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
    proc.stdinEnabled = true
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

  FileView {
    id: systemFile
    path: llm.stateDir + "/" + llm.name + "-system-prompt.txt"
    blockWrites: true
    atomicWrites: true
    printErrors: false
  }

  Process {
    id: proc
    property string input: ""
    workingDirectory: llm.stateDir
    // 写完立即关闭 stdin，CLI 读到 EOF 才开始
    onStarted: {
      proc.write(proc.input)
      proc.stdinEnabled = false
      proc.input = ""
    }
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
