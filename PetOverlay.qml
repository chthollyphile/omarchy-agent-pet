import QtQuick
import Quickshell
import Quickshell.Wayland

// 一块屏一个全屏透明 layer-shell 窗口，宠物在窗口内自由移动 / 被甩飞。
// 输入区域（mask）只包含宠物身体和对话框，其余位置点击穿透到下面的窗口；
// 右键菜单打开期间整个窗口接收输入，点空白处关闭菜单。
PanelWindow {
  id: win

  property var service
  property var pets: []

  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }
  color: "transparent"
  // Normal + exclusiveZone 0：窗口只占可用区域，不压 bar；窗口底边就是宠物的地面
  exclusionMode: ExclusionMode.Normal
  exclusiveZone: 0
  WlrLayershell.namespace: "agent-pet"
  WlrLayershell.layer: service.config.layer === "overlay" ? WlrLayer.Overlay : WlrLayer.Top
  WlrLayershell.keyboardFocus: chat.open || menu.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
  visible: !service.hidden

  property var petRegions: []

  // PanelWindow 的 width/height 是 implicit 尺寸的别名，四边锚定时恒为 0；真实尺寸从填满窗口的 Item 取
  Item {
    id: area
    anchors.fill: parent
  }
  readonly property real areaW: area.width
  readonly property real areaH: area.height

  function rebuildRegions() {
    var out = []
    for (var i = 0; i < petRepeater.count; i++) {
      var item = petRepeater.itemAt(i)
      if (item) out.push(item.hitRegion)
    }
    out.push(chatRegion)
    petRegions = out
  }

  Region {
    id: fullRegion
    x: 0
    y: 0
    width: win.areaW
    height: win.areaH
  }

  Region {
    id: chatRegion
    x: chat.x
    y: chat.y
    width: chat.open ? chat.width : 0
    height: chat.open ? chat.height : 0
  }

  mask: Region {
    regions: menu.open ? [fullRegion] : win.petRegions
  }

  Repeater {
    id: petRepeater
    model: win.pets

    Pet {
      required property var modelData
      cfg: modelData
      service: win.service
      overlay: win
    }

    onItemAdded: win.rebuildRegions()
    onItemRemoved: win.rebuildRegions()
  }

  function openMenu(pet, px, py) {
    menu.show(pet, px, py)
  }

  function openChat(pet) {
    chat.show(pet)
  }

  PetMenu {
    id: menu
    anchors.fill: parent
    service: win.service
  }

  ChatInput {
    id: chat
    service: win.service
    areaWidth: win.areaW
    areaHeight: win.areaH
  }
}
