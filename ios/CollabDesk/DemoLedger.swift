import Foundation
extension Snapshot {
    mutating func seedDemoLedger() {
        guard (libraries ?? []).isEmpty else { return }
        if let i=tasks.firstIndex(where:{ $0.status == .awaiting_review }) { tasks[i].reviewStage="user" }
        let stamp=DeskDate.string(), owner=members.first { $0.role == "worker" }?.id ?? me.id
        let fields=[LedgerField(id:"status",name:"状态",type:"status",options:["未开始","进行中","完成","已取消"]),LedgerField(id:"rating",name:"推荐度",type:"rating"),LedgerField(id:"owner",name:"所有者",type:"member"),LedgerField(id:"date",name:"日期",type:"date"),LedgerField(id:"url",name:"原始链接",type:"url"),LedgerField(id:"notes",name:"备注",type:"longtext")]
        libraries=[RecordLibrary(id:1,name:"资料追踪 · 演示",fields:fields,views:[LedgerViewDefinition(id:"priority",name:"优先处理",filters:[LedgerFilter(fieldId:"status",op:"not_equals",value:.string("完成")),LedgerFilter(fieldId:"status",op:"not_equals",value:.string("已取消"))],sorts:[LedgerSort(fieldId:"rating",descending:true)])],workerAccess:"write",version:1,createdBy:me.id,createdAt:stamp,updatedAt:stamp)]
        records=[LedgerRecord(id:1,libraryId:1,title:"一份待整理的资料",values:["status":.string("进行中"),"rating":.int(5),"owner":.string(owner),"notes":.string("这是本地样例，不会上传到服务。")],body:"# 资料页面\n\n## 原始内容\n在这里存放完整资料、文章和上下文。\n\n## 当前进展\n- Leader 分配任务\n- Worker 在同一条记录补充正文\n\n## 成果与备注\n任务和资料相互关联，变更保留历史。",archived:false,version:1,taskIds:tasks.first.map { [$0.id] } ?? [],createdBy:me.id,createdAt:stamp,updatedAt:stamp)]
    }
}
