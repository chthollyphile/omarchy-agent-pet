import QtQuick
import Quickshell
import Quickshell.Io

// hook 事件入口：bin/agent-pet-hook 经 socat 把一行 JSON 写进这个 Unix socket。
// 事件内容只走管道和 socket，进程参数里只有 socket 路径。
//
// 针对 Quickshell SocketServer 的两处处理（quickshell-git 0.3.0）：
// - 对端先断开时会记一条 PeerClosedError 警告：读完一行由这边断开，hook 端 socat 用 shut-none 不半关闭；
// - 断开的连接对象要等监听停掉才释放（每个约 2 KB）：累计一批且没有未断开的连接时重建一次监听。
Scope {
  id: events

  // 父目录要先建好（0700）再调用 start()
  property string path: ""
  signal received(string line)

  readonly property int recycleAfter: 500
  property int accepted: 0
  property int open: 0

  function start() {
    server.active = true
  }

  function recycle() {
    if (accepted < recycleAfter || open > 0) return
    accepted = 0
    server.active = false
    server.active = true
  }

  SocketServer {
    id: server
    path: events.path

    handler: Socket {
      id: conn

      onConnectionStateChanged: {
        if (connected) {
          events.open++
          events.accepted++
        } else {
          events.open--
          Qt.callLater(events.recycle)
        }
      }

      parser: SplitParser {
        onRead: line => {
          events.received(line)
          // 一个连接只送一行；等当前读取处理完再断开
          Qt.callLater(() => {
            if (conn) conn.connected = false
          })
        }
      }
    }
  }
}
