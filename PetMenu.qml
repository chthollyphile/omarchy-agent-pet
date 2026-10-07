import QtQuick
import qs.Commons
import "lib/shared.mjs" as Shared
import "lib/i18n.mjs" as I18n

// 右键菜单：动作 → 分类 → 动画（树来自 dsh-pet 的 buildMenuTree）+ 工具项。
// 逐级展开的独立列；打开期间 overlay 整窗接收输入，点空白处或 Esc 关闭。
Item {
  id: menu

  property var service
  property bool open: false
  property var pet: null
  property var tree: []
  // 每一级当前展开的节点下标：path[0] = 第一列选中项
  property var path: []
  property real originX: 0
  property real originY: 0

  readonly property int rowH: 26
  readonly property int colW: 168

  visible: open
  focus: open

  function show(targetPet, px, py) {
    pet = targetPet
    var t = I18n.translateMenuTree(Shared.buildMenuTree(targetPet.anims), service.lang)
    var tools = []
    if (targetPet.cfg.whisperEnabled !== false) tools.push({ label: service.tr(service.llmBusy ? "menuWhisperBusy" : "menuWhisper"), action: "whisper" })
    tools.push({ label: service.tr("menuChat"), action: "chat" })
    if (targetPet.cfg.balanceEnabled !== false) tools.push({ label: service.tr("menuUsage"), action: "usage" })
    tools.push({ label: service.tr("menuHome"), action: "home" })
    tools.push({ label: service.tr("menuReload"), action: "reload" })
    tools.push({ label: service.tr("menuHide"), action: "hide" })
    tree = t.concat(tools)
    path = []
    originX = px
    originY = py
    open = true
  }

  function close() {
    open = false
    path = []
  }

  function columnItems(level) {
    var items = tree
    for (var i = 0; i < level; i++) {
      var node = items[path[i]]
      if (!node || !node.children) return []
      items = node.children
    }
    return items
  }

  readonly property int columnCount: {
    var n = 1
    var items = tree
    for (var i = 0; i < path.length; i++) {
      var node = items[path[i]]
      if (!node || !node.children) break
      items = node.children
      n++
    }
    return n
  }

  function hover(level, index) {
    var next = path.slice(0, level)
    next.push(index)
    path = next
  }

  function activate(level, index) {
    var node = columnItems(level)[index]
    if (!node) return
    if (node.children) {
      hover(level, index)
      return
    }
    var target = pet
    close()
    if (target) target.menuAction(node)
  }

  // 点空白关闭
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onPressed: menu.close()
  }

  // 整体靠左展开还是靠右：放不下就翻到点击点左边
  readonly property bool flipLeft: originX + colW * Math.max(columnCount, 3) > width

  Repeater {
    model: menu.columnCount

    Rectangle {
      id: col
      required property int index
      readonly property var items: menu.columnItems(index)
      // 子列与父列选中行对齐，超出底部则上移
      readonly property real wantY: index === 0 ? menu.originY : menu.originY + menu.rowOffset(index) * menu.rowH
      x: menu.flipLeft ? menu.originX - (index + 1) * menu.colW : menu.originX + index * menu.colW
      y: Math.max(4, Math.min(menu.height - height - 4, wantY))
      width: menu.colW
      height: Math.min(items.length * menu.rowH + 8, menu.height - 8)
      radius: Style.cornerRadius
      color: Color.menu.background
      border.color: Color.menu.border
      border.width: 1
      clip: true

      Flickable {
        anchors.fill: parent
        anchors.margins: 4
        contentHeight: list.height
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: list
          width: parent.width

          Repeater {
            model: col.items

            Rectangle {
              id: row
              required property var modelData
              required property int index
              readonly property bool selected: menu.path[col.index] === index
              width: list.width
              height: menu.rowH
              color: selected || area.containsMouse ? Color.menu.selectedBackground : "transparent"

              Text {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.right: arrow.left
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.label
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: row.selected ? Color.menu.selectedText : Color.menu.text
                font.family: Style.fontFamily
                font.pixelSize: 13
              }

              Text {
                id: arrow
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.children ? "›" : ""
                color: Color.menu.text
                font.pixelSize: 13
              }

              MouseArea {
                id: area
                anchors.fill: parent
                hoverEnabled: true
                onEntered: if (row.modelData.children) menu.hover(col.index, row.index)
                  else if (menu.path.length > col.index) menu.path = menu.path.slice(0, col.index)
                onClicked: menu.activate(col.index, row.index)
              }
            }
          }
        }
      }
    }
  }

  // 第 level 列应对齐到的行：前面各列选中行的累计偏移
  function rowOffset(level) {
    var off = 0
    for (var i = 0; i < level; i++) off += path[i] || 0
    return off
  }

  Keys.onEscapePressed: close()
}
