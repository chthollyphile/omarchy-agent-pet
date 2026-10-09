import QtQuick
import Quickshell
import Quickshell.Io
import "lib/jsonc.mjs" as Jsonc
import "lib/work-status.mjs" as WS
import "lib/usage.mjs" as Usage
import "lib/i18n.mjs" as I18n

// agent-pet 的状态中枢：配置、Claude Code / Codex 工作状态聚合、用量、LLM、通知、IPC。
// 每块有宠物的屏幕各一个 PetOverlay（全屏透明 layer-shell 窗口）。
Scope {
  id: root

  // 宿主注入
  property var shell: null
  property string omarchyPath: ""
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string userConfigPath: home + "/.config/agent-pet/config.jsonc"
  readonly property string stateDir: home + "/.local/state/agent-pet"
  // hook 事件 socket 所在目录（0700），与 bin/agent-pet-hook 一致
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") + "/agent-pet"

  // ------------------------------------------------------------ 配置
  property var config: ({})
  property bool ready: false
  property string configError: ""
  property int assetFps: 15
  property bool hidden: false
  // 界面语言：language 设置（auto / zh / en），auto 从 LANGUAGE / LC_ALL / LC_MESSAGES / LANG 判断
  property string lang: "zh"

  function tr(key, params) {
    return I18n.t(lang, key, params)
  }

  readonly property var pets: (config.pets || []).filter(function(p) { return p.display !== "none" })

  function rebuildConfig() {
    var base
    try {
      base = JSON.parse(defaultFile.text())
    } catch (e) {
      console.warn("[agent-pet] 内置配置解析失败:", e)
      return
    }
    var merged = Object.assign({}, base)
    var user = {}
    configError = ""
    var userText = userFile.loaded ? userFile.text() : ""
    if (userText.trim() !== "") {
      try {
        // 顶层整段替换（与 dsh-pet 同口径）：写了哪个字段就整段用用户的
        user = Jsonc.parseJsonc(userText) || {}
        Object.assign(merged, user)
      } catch (e) {
        configError = String(e)
        console.warn("[agent-pet] 用户配置解析失败，使用内置配置:", e)
      }
    }
    try {
      assetFps = Number(JSON.parse(assetManifest.text()).fps) || 15
    } catch (e) {}
    lang = I18n.resolveLang(merged.language, {
      LANGUAGE: Quickshell.env("LANGUAGE") || "",
      LC_ALL: Quickshell.env("LC_ALL") || "",
      LC_MESSAGES: Quickshell.env("LC_MESSAGES") || "",
      LANG: Quickshell.env("LANG") || ""
    })
    // 内置文案是中文：英文界面下，用户没自定义的就换成英文版
    if (lang === "en") {
      if (!("workStatusTexts" in user)) merged.workStatusTexts = I18n.WORK_STATUS_TEXTS_EN
      if (!("whisperPrompt" in user)) merged.whisperPrompt = I18n.WHISPER_PROMPT_EN
    }
    config = merged
    ready = true
    // restart() 会冲掉 running 绑定，所以按开关显式启停，否则 whisperAuto=false 也会定时碎碎念
    if (merged.whisperAuto === true) whisperTimer.restart()
    else whisperTimer.stop()
    usageTimer.restart()
    if (configError) speak("", tr("configError", { error: configError }), "", "error")
  }

  function reloadConfig() {
    userFile.reload()
    defaultFile.reload()
  }

  FileView {
    id: defaultFile
    path: root.pluginDir + "/assets/config.json"
    blockLoading: true
    onLoaded: root.rebuildConfig()
  }

  FileView {
    id: assetManifest
    path: root.pluginDir + "/assets/webp/manifest.json"
    blockLoading: true
    printErrors: false
  }

  FileView {
    id: userFile
    path: root.userConfigPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: if (defaultFile.loaded) root.rebuildConfig()
    onLoadFailed: if (defaultFile.loaded) root.rebuildConfig()
  }

  // ------------------------------------------------------------ 宠物对外信号
  // petId 为空 = 所有宠物
  signal speak(string petId, string text, string meme, string kind)
  signal playRequest(string petId, string name)
  signal usageShow(var summary)

  // ------------------------------------------------------------ 工作状态
  property var wsStore: WS.createStore()
  // 当前展示的会话快照（对象引用变化 = 宠物要切档位）；null = 没有活跃会话
  property var workStatus: null
  property string lastAgent: "claude"

  function agentEnabled(agent) {
    var a = config.agents || {}
    return a[agent] !== false
  }

  // hook 经 socat 把事件写进 runtimeDir/events.sock，每行一个 JSON（事件内容不进进程参数）
  EventServer {
    id: eventServer
    path: root.runtimeDir + "/events.sock"
    onReceived: line => root.handleEvent(line)
  }

  function handleEvent(json) {
    var ev
    try {
      ev = JSON.parse(json)
    } catch (e) {
      return "bad-json"
    }
    if (!ev || !ev.event) return "bad-event"
    if (!agentEnabled(ev.agent)) return "ignored"
    if (ev.agent === "claude" || ev.agent === "codex") lastAgent = ev.agent
    var res = WS.applyEvent(wsStore, ev, Date.now())
    if (res.entered) notifyFor(res.entry)
    if (res.changed) refreshWorkStatus()
    var mode = summaryMode()
    if (mode === "model") {
      // 新一轮还没有总结时，第一步出现后稍等几秒先总结一次，不必等满 intervalSec
      if (res.entry && res.entry.steps.length && !res.entry.summary && !summaryKick.running) summaryKick.restart()
    } else if (mode === "transcript" && res.entry) {
      if (ev.event === "Stop" && ev.lastMessage) {
        // Stop 自带最后一条回复，不用读文件
        if (WS.setSummary(wsStore, res.entry.key, WS.formatNarration(ev.lastMessage))) refreshWorkStatus()
      } else if (ev.event === "PreToolUse" || ev.event === "Stop") {
        narrationKey = res.entry.key
        narrationDelay.restart()
      }
    }
    return "ok"
  }

  function refreshWorkStatus() {
    var cur = WS.current(wsStore)
    var prev = workStatus
    if (!cur) {
      if (prev) workStatus = null
      return
    }
    // 档位、工具、命令或总结任一变化都发新快照；宠物只在会话 / 档位变化时切动画，其余只刷新气泡
    if (prev && prev.key === cur.key && prev.state === cur.state && prev.tool === cur.tool
      && prev.detail === cur.detail && prev.summary === cur.summary) return
    workStatus = Object.assign({}, cur)
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: if (WS.prune(root.wsStore, Date.now())) root.refreshWorkStatus()
  }

  // ------------------------------------------------------------ 系统通知
  readonly property var notifyTitleKeys: ({ waiting: "notifyWaiting", success: "notifySuccess", error: "notifyError" })
  readonly property var notifyIcons: ({ waiting: "approval", success: "done", error: "error" })
  // 完整通知（含项目名和消息）经 stdin 交给 bin/agent-pet-notify，由它直接走 D-Bus，不进进程参数。
  // 没有 PyGObject（gi）时退回 notify-send：它只能从命令行参数拿文本，所以只发固定文字。
  property bool notifyViaDbus: true
  property var notifyQueue: []

  function notifyFor(entry) {
    if (config.notificationsEnabled === false) return
    var titleKey = notifyTitleKeys[entry.state]
    if (!titleKey) return
    var title = tr(titleKey)
    var onlyUnfocused = !config.notify || config.notify.onlyWhenUnfocused !== false
    if (onlyUnfocused && entry.focused) return
    var agentName = entry.agent === "codex" ? "Codex" : "Claude Code"
    var project = WS.projectName(entry.cwd)
    var n = {
      app: "agent-pet",
      icon: root.pluginDir + "/assets/pic/notify-" + notifyIcons[entry.state] + ".png",
      summary: agentName + (project ? " · " + project : "") + " · " + title,
      body: entry.message || entry.tool || "",
      fixedSummary: agentName + " · " + title
    }
    if (!notifyViaDbus) {
      notifyFixed(n)
      return
    }
    notifyQueue = notifyQueue.concat([n])
    nextNotify()
  }

  function notifyFixed(n) {
    Quickshell.execDetached(["notify-send", "-a", n.app, "-i", n.icon, n.fixedSummary])
  }

  function nextNotify() {
    while (notifyQueue.length && !notifyProc.running) {
      var n = notifyQueue[0]
      notifyQueue = notifyQueue.slice(1)
      if (!notifyViaDbus) {
        notifyFixed(n)
        continue
      }
      notifyProc.current = n
      notifyProc.lastExit = -1
      notifyProc.stdinEnabled = true
      notifyProc.running = true
    }
  }

  Process {
    id: notifyProc
    property var current: null
    property int lastExit: -1
    command: [root.pluginDir + "/bin/agent-pet-notify"]
    onStarted: {
      write(JSON.stringify(current))
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      lastExit = exitCode
    }
    // 启动失败时只有 runningChanged、没有 exited，所以在这里收尾。
    // 3 = 没有 gi，-1 = 脚本没能启动：之后都直接发固定文字
    onRunningChanged: {
      if (running) return
      if (lastExit === 3 || lastExit === -1) root.notifyViaDbus = false
      if (lastExit !== 0) root.notifyFixed(current)
      root.nextNotify()
    }
  }

  // ------------------------------------------------------------ 用量
  // 数据源：
  //   omarchy = omarchy.agents 插件的记录（由 omarchy-agent-usage-update 生成），Omarchy 上直接用
  //   builtin = bin/agent-pet-usage 自己采集，行为移植自 omarchy agents 的采集脚本，供非 Omarchy 环境使用
  // usage.source 可强制指定；默认 auto = 能找到 omarchy-agent-usage-update 就用 omarchy
  property string omarchyCollector: ""
  property bool usageSourceChecked: false
  readonly property string usageSource: {
    var s = (config.usage || {}).source
    if (s === "omarchy" || s === "builtin") return s
    return omarchyCollector ? "omarchy" : "builtin"
  }
  readonly property string usageDir: !usageSourceChecked ? ""
    : usageSource === "omarchy" ? home + "/.local/state/omarchy/agents/usage" : stateDir + "/usage"
  // 原始记录：倒计时在显示时才计算，避免读取后过一阵再显示时倒计时不准
  property var usageRecords: ({})
  property var usageTiers: ({})
  property bool usageShowPending: false
  property bool usageShowManual: false

  Process {
    running: true
    command: ["bash", "-c", "command -v omarchy-agent-usage-update || { [ -x \"$OMARCHY_PATH/bin/omarchy-agent-usage-update\" ] && echo \"$OMARCHY_PATH/bin/omarchy-agent-usage-update\"; } || true"]
    stdout: StdioCollector { id: collectorOut }
    onExited: {
      root.omarchyCollector = collectorOut.text.trim()
      root.usageSourceChecked = true
      console.log("[agent-pet] 用量数据源: " + root.usageSource + (root.usageSource === "omarchy" ? " (" + root.omarchyCollector + ")" : ""))
    }
  }

  function usageAgent() {
    var u = config.usage || {}
    return u.agent && u.agent !== "auto" ? u.agent : lastAgent
  }

  function enabledUsageAgents() {
    return ["claude", "codex"].filter(function(a) { return agentEnabled(a) })
  }

  function usageAgeMs(agent) {
    var rec = usageRecords[agent]
    var t = rec ? Date.parse(rec.updatedAt) : NaN
    return isFinite(t) ? Date.now() - t : Infinity
  }

  function updateUsage(agent, text) {
    var rec = null
    try {
      rec = JSON.parse(text)
    } catch (e) {}
    var next = Object.assign({}, usageRecords)
    next[agent] = rec
    usageRecords = next
    var summary = rec ? Usage.summarize(rec, Date.now(), lang) : null
    var prevTier = usageTiers[agent]
    var tiers = Object.assign({}, usageTiers)
    tiers[agent] = summary ? summary.tier : -1
    usageTiers = tiers
    // 首次读取不播；之后档位变化时播一次（等待中的手动查看会自己显示，这里不重复）
    if (summary && prevTier !== undefined && prevTier !== summary.tier && agent === usageAgent() && !usageShowPending)
      usageShow(summary)
  }

  // 先刷新再显示：记录超过 60 秒没更新就重新采集（manual = 用户主动查看，期间提示"正在刷新"）
  function showUsage(manual) {
    var agent = usageAgent()
    if (!usageRecords[agent] && usageRecords[agent === "claude" ? "codex" : "claude"]) agent = agent === "claude" ? "codex" : "claude"
    if (usageAgeMs(agent) > 60000 && usageSourceChecked) {
      if (manual) speak("", tr("usageRefreshing"), "", "info")
      usageShowManual = usageShowManual || manual
      refreshUsage([agent], true)
      return
    }
    displayUsage(manual)
  }

  function displayUsage(manual) {
    var agent = usageAgent()
    var rec = usageRecords[agent] || usageRecords[agent === "claude" ? "codex" : "claude"]
    var summary = rec ? Usage.summarize(rec, Date.now(), lang) : null
    if (summary) usageShow(summary)
    else if (manual) speak("", tr(usageSource === "omarchy" ? "usageNoDataOmarchy" : "usageNoDataBuiltin"), "", "info")
  }

  function refreshUsage(agents, showAfter) {
    if (showAfter) usageShowPending = true
    if (usageProc.running || !usageSourceChecked || !agents.length) return
    var cmd = usageSource === "omarchy"
      ? [omarchyCollector || "omarchy-agent-usage-update", "--limits-only"]
      : [root.pluginDir + "/bin/agent-pet-usage"]
    usageProc.command = cmd.concat(agents)
    usageProc.running = true
    usageRefreshTimeout.restart()
  }

  Process {
    id: usageProc
    onExited: {
      usageRefreshTimeout.stop()
      claudeUsageFile.reload()
      codexUsageFile.reload()
      if (root.usageShowPending) usageShowDelay.restart()
    }
  }

  Timer {
    id: usageRefreshTimeout
    interval: 20000
    onTriggered: if (usageProc.running) usageProc.signal(15)
  }

  // 等文件重新读完再显示；刷新失败时显示旧数据（气泡会注明是多久前的）
  Timer {
    id: usageShowDelay
    interval: 400
    onTriggered: {
      var manual = root.usageShowManual
      root.usageShowPending = false
      root.usageShowManual = false
      root.displayUsage(manual)
    }
  }

  FileView {
    id: claudeUsageFile
    path: root.usageDir ? root.usageDir + "/claude.json" : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.updateUsage("claude", text())
  }

  FileView {
    id: codexUsageFile
    path: root.usageDir ? root.usageDir + "/codex.json" : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.updateUsage("codex", text())
  }

  // 定时显示（余额动画周期）
  Timer {
    id: usageTimer
    interval: Math.max(60, Number((root.config.eventsRefreshSec || {}).balance) || 1800) * 1000
    running: root.ready
    repeat: true
    onTriggered: root.showUsage(false)
  }

  // 后台保鲜：记录比 usage.refreshSec 旧就重新采集（Omarchy 上 agents 组件通常已在刷新，这里基本不触发）
  Timer {
    interval: Math.max(60, Number((root.config.usage || {}).refreshSec) || 900) * 1000
    running: root.ready && root.usageSourceChecked
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      var limit = interval
      var stale = root.enabledUsageAgents().filter(function(a) { return root.usageAgeMs(a) > limit })
      if (stale.length) root.refreshUsage(stale, false)
    }
  }

  // ------------------------------------------------------------ 碎碎念 / 对话（只在显式触发或 whisperAuto 开启时调用 LLM）
  Llm {
    id: llm
    name: "chat"
    lang: root.lang
    home: root.home
    stateDir: root.stateDir
    onFinished: function(petId, kind, text, meme, failed) {
      if (failed) {
        root.speak(petId, text, "", "error")
        return
      }
      if (kind === "chat") root.rememberChat(petId, llm.lastUserText, text)
      root.speak(petId, text, root.knownMeme(meme), kind)
    }
  }

  readonly property bool llmBusy: llm.busy

  // 自动任务（步骤总结、定时碎碎念）专用：独立实例，不和手动对话抢；用 autoModel 指定的便宜模型
  Llm {
    id: autoLlm
    name: "auto"
    lang: root.lang
    home: root.home
    stateDir: root.stateDir
    onFinished: function(petId, kind, text, meme, failed) {
      if (kind === "summary") {
        if (failed) {
          console.warn("[agent-pet] 步骤总结失败:", text)
          return
        }
        if (WS.setSummary(root.wsStore, autoLlm.tag, text.replace(/\s+/g, " ").slice(0, 30))) root.refreshWorkStatus()
        return
      }
      if (failed) console.warn("[agent-pet] 定时碎碎念失败:", text)
      else root.speak(petId, text, meme, kind)
    }
  }

  function autoModelFor() {
    var a = config.autoModel || {}
    var provider = a.provider === "codex" ? "codex" : "claude"
    return { provider: provider, model: (provider === "codex" ? a.codexModel : a.claudeModel) || "" }
  }

  // ------------------------------------------------------------ 步骤总结（stepSummary.enabled，默认关）
  readonly property var stepSummaryCfg: config.stepSummary || ({})

  // off / transcript（读会话记录里 agent 自己写的话）/ model（用 autoModel 总结）；旧写法 enabled: true 视为 model
  function summaryMode() {
    var c = stepSummaryCfg
    if (c.mode === "off" || c.mode === "transcript" || c.mode === "model") return c.mode
    return c.enabled === true ? "model" : "off"
  }

  // ---- transcript 模式：从会话记录末尾读本轮最新一段 assistant 文字
  property string narrationKey: ""
  property bool narrationPending: false

  function readNarration() {
    var entry = wsStore.sessions[narrationKey]
    if (!entry || !entry.transcript) return
    if (narrationProc.running) {
      narrationPending = true
      return
    }
    narrationProc.key = entry.key
    // 会话记录路径含项目路径和会话 ID，走环境变量（只有本用户可读），不放进进程参数
    narrationProc.environment = ({
      AGENT_PET_TRANSCRIPT: entry.transcript,
      AGENT_PET_SINCE: new Date(entry.turnAt - 2000).toISOString()
    })
    narrationProc.command = [root.pluginDir + "/bin/agent-pet-last-message"]
    narrationProc.running = true
  }

  // hook 有时比记录文件写入早一点：稍等再读
  Timer {
    id: narrationDelay
    interval: 500
    onTriggered: root.readNarration()
  }

  Process {
    id: narrationProc
    property string key: ""
    stdout: StdioCollector { id: narrationOut }
    onExited: function(exitCode) {
      var text = WS.formatNarration(narrationOut.text)
      // 没读到（记录还没写入 / 本轮还没说话）就保留上一段，不清空
      if (exitCode === 0 && text && WS.setSummary(root.wsStore, narrationProc.key, text)) root.refreshWorkStatus()
      if (root.narrationPending) {
        root.narrationPending = false
        root.readNarration()
      }
    }
  }
  property var summarizedSeq: ({})

  function summarizeCurrentStep() {
    var cur = WS.current(wsStore)
    if (!cur || WS.isTerminal(cur.state) || !cur.steps.length) return
    if (summarizedSeq[cur.key] === cur.stepSeq || autoLlm.busy) return
    var seen = Object.assign({}, summarizedSeq)
    seen[cur.key] = cur.stepSeq
    summarizedSeq = seen
    var system = tr("summarySystem")
    var prompt = tr("summaryRequest", { prompt: cur.prompt || tr("summaryUnknown") }) + "\n" + tr("summarySteps") + "\n"
      + cur.steps.map(function(st, i) { return (i + 1) + ". " + WS.formatDetail(st.tool, st.detail, cur.cwd, 100) }).join("\n")
    var m = autoModelFor()
    autoLlm.tag = cur.key
    autoLlm.run(m.provider, m.model, system, prompt, "", "summary", "", true)
  }

  Timer {
    id: summaryKick
    interval: 8000
    onTriggered: root.summarizeCurrentStep()
  }

  Timer {
    interval: Math.max(20, Number(root.stepSummaryCfg.intervalSec) || 60) * 1000
    running: root.ready && root.summaryMode() === "model"
    repeat: true
    triggeredOnStart: true
    onTriggered: root.summarizeCurrentStep()
  }

  function petById(petId) {
    for (var i = 0; i < pets.length; i++) if (pets[i].id === petId) return pets[i]
    return pets.length ? pets[0] : null
  }

  function memeNames() {
    return Object.keys(config.memes || {})
  }

  // 对话回复里的表情包名由模型给出，而名字会拼进图片路径：只认配置里有的
  function knownMeme(name) {
    var memes = config.memes || {}
    return name && Object.prototype.hasOwnProperty.call(memes, name) ? name : ""
  }

  function persona(pet) {
    return (config.whisperPrompt || "") + (lang === "en" ? " " : "") + tr("personaName", { name: pet.name || pet.id })
  }

  function llmModel() {
    var l = config.llm || {}
    return (l.provider === "codex" ? l.codexModel : l.claudeModel) || ""
  }

  function requestWhisper(petId, auto) {
    var pet = petById(petId)
    if (!pet) return "no-pet"
    var runner = auto ? autoLlm : llm
    if (runner.busy) return "busy"
    var meme = ""
    var names = memeNames()
    if (config.whisperImageEnabled !== false && names.length) meme = names[Math.floor(Math.random() * names.length)]
    var now = new Date()
    var sep = lang === "en" ? " " : ""
    var prompt = tr("whisperNow", { time: Qt.formatTime(now, "HH:mm") })
    if (meme) prompt += sep + tr("whisperMeme", { desc: config.memes[meme] })
    prompt += sep + tr("whisperOutput")
    if (auto) {
      var m = autoModelFor()
      autoLlm.run(m.provider, m.model, persona(pet), prompt, pet.id, "whisper", meme, true)
    } else {
      llm.run((config.llm || {}).provider, llmModel(), persona(pet), prompt, pet.id, "whisper", meme, false)
    }
    return "ok"
  }

  function requestChat(petId, text) {
    var pet = petById(petId)
    if (!pet || !text) return "no-pet"
    if (llm.busy) return "busy"
    var sep = lang === "en" ? " " : ""
    var system = persona(pet) + sep + tr("chatIntro")
    var useMemes = config.chatImageEnabled !== false && memeNames().length > 0
    if (useMemes) {
      var limit = Number(config.chatImageLimit)
      var names = memeNames()
      if (limit > 0) names = names.slice(0, limit)
      system += sep + tr("chatJson") + sep
        + tr("chatMemes", { list: names.map(function(n) { return n + (lang === "en" ? ": " : "：") + config.memes[n] }).join(lang === "en" ? "; " : "；") })
    } else {
      system += sep + tr("chatPlain")
    }
    var rounds = Number(config.chatMemoryRounds)
    if (!(rounds >= 0)) rounds = 5
    var history = chatHistory(pet.id).slice(-rounds)
    var prompt = history.map(function(h) { return tr("chatOwner") + h.q + "\n" + tr("chatYou") + h.a }).join("\n")
    prompt += (prompt ? "\n" : "") + tr("chatOwner") + text
    llm.lastUserText = text
    llm.run((config.llm || {}).provider, llmModel(), system, prompt, pet.id, "chat", "", false)
    return "ok"
  }

  Timer {
    id: whisperTimer
    interval: Math.max(60, Number((root.config.eventsRefreshSec || {}).whisper) || 300) * 1000
    running: root.ready && root.config.whisperAuto === true
    repeat: true
    onTriggered: {
      // 有 agent 正在干活时不打扰，也不和它抢额度
      if (WS.anyBusy(root.wsStore)) return
      for (var i = 0; i < root.pets.length; i++) {
        if (root.pets[i].whisperEnabled !== false) {
          root.requestWhisper(root.pets[i].id, true)
          return
        }
      }
    }
  }

  // 对话记忆：{ petId: [{ q, a, t }] }，全量保存，每次请求只截最近 chatMemoryRounds 轮
  property var memory: ({})

  function chatHistory(petId) {
    return memory[petId] || []
  }

  function rememberChat(petId, q, a) {
    var next = Object.assign({}, memory)
    next[petId] = chatHistory(petId).concat([{ q: q, a: a, t: Date.now() }])
    memory = next
    memoryFile.setText(JSON.stringify(next, null, 2))
  }

  FileView {
    id: memoryFile
    path: root.stateDir + "/memory.json"
    printErrors: false
    onLoaded: {
      try {
        root.memory = JSON.parse(text()) || {}
      } catch (e) {
        root.memory = {}
      }
    }
  }

  // 对话记忆、模型提示词文件和事件 socket 只给本用户访问；目录建好后再开始监听
  Process {
    running: true
    command: ["bash", "-c", 'mkdir -p -m 700 "$@"; chmod 700 "$@"', "_", root.stateDir, root.runtimeDir]
    onExited: function(exitCode) {
      if (exitCode === 0) eventServer.start()
      else console.warn("[agent-pet] 无法创建 " + root.runtimeDir + "，收不到 hook 事件")
    }
  }

  // ------------------------------------------------------------ IPC：omarchy-shell agent-pet <method> [arg]
  IpcHandler {
    target: "agent-pet"

    function say(text: string): string {
      root.speak("", text, "", "info")
      return "ok"
    }
    function play(name: string): string {
      root.playRequest("", name)
      return "ok"
    }
    function usage(): string {
      root.showUsage(true)
      return "ok"
    }
    function whisper(): string {
      return root.requestWhisper("", false)
    }
    function chat(text: string): string {
      return root.requestChat("", text)
    }
    function reload(): string {
      root.reloadConfig()
      return "ok"
    }
    function toggle(): string {
      root.hidden = !root.hidden
      return root.hidden ? "hidden" : "shown"
    }
    function state(): string {
      return JSON.stringify({
        ready: root.ready,
        hidden: root.hidden,
        configError: root.configError,
        pets: root.pets.map(function(p) { return p.id }),
        workStatus: root.workStatus,
        sessions: root.wsStore.sessions,
        lastAgent: root.lastAgent,
        usageSource: root.usageSource,
        usage: Object.keys(root.usageRecords).reduce(function(o, a) {
          var r = root.usageRecords[a]
          o[a] = r ? { updatedAt: r.updatedAt, summary: Usage.summarize(r, Date.now(), root.lang) } : null
          return o
        }, {}),
        llmBusy: llm.busy,
        autoBusy: autoLlm.busy,
        autoModel: root.autoModelFor(),
        stepSummary: root.summaryMode(),
        lang: root.lang,
        whisperAuto: root.config.whisperAuto === true
      })
    }
  }

  // ------------------------------------------------------------ 每块屏一个透明 overlay
  function screenName(pet) {
    var screens = Quickshell.screens
    if (pet.screen) {
      for (var i = 0; i < screens.length; i++) if (screens[i].name === pet.screen) return pet.screen
    }
    return screens.length ? screens[0].name : ""
  }

  function petsForScreen(screen) {
    return pets.filter(function(p) { return screenName(p) === screen.name })
  }

  Variants {
    model: root.ready ? Quickshell.screens.filter(function(s) { return root.petsForScreen(s).length > 0 }) : []

    PetOverlay {
      required property var modelData
      screen: modelData
      service: root
      pets: root.petsForScreen(modelData)
    }
  }
}
