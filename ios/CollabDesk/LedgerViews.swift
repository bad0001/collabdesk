import SwiftUI
import UniformTypeIdentifiers

struct LibrariesView: View {
    @EnvironmentObject var store: DeskStore
    @State private var create = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading, spacing:16) {
                    ForEach(store.snapshot.libraries ?? []) { lib in
                        NavigationLink { LibraryTableView(libraryID:lib.id) } label: {
                            Panel {
                                HStack(spacing:14) {
                                    SoftIcon(symbol:"tablecells")
                                    VStack(alignment:.leading, spacing:6) {
                                        Text(lib.name).font(.headline).foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)
                                        Text("\((store.snapshot.records ?? []).filter { $0.libraryId == lib.id && !$0.archived }.count) 条记录 · \(lib.fields.count) 个字段")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength:8)
                                    Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                    if (store.snapshot.libraries ?? []).isEmpty {
                        EmptyPanel(title:"还没有记录库", detail:store.snapshot.me.privileged ? "由 Leader 建立，或点击右上角新增。" : "当前没有与你任务关联的资料。", symbol:"tablecells")
                    }
                    if let backup = store.snapshot.backupStatus {
                        Panel {
                            DisclosureGroup {
                                VStack(alignment:.leading, spacing:8) {
                                    Text(backup.latest.map { "最近备份：\(DeskDate.display($0.createdAt))" } ?? "服务端定期备份尚未生成")
                                    Text("服务运行时每日备份，保留 \(backup.retainedCopies) 份。异地备份尚待配置。")
                                }.font(.caption).foregroundStyle(.secondary).padding(.top,12)
                            } label: {
                                Label("备份状态", systemImage:"externaldrive.badge.checkmark")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }.tint(.secondary)
                        }
                    }
                }.padding(18)
            }.background(DeskStyle.background).navigationTitle("台账").navigationBarTitleDisplayMode(.inline)
                .toolbar { if store.snapshot.me.privileged { Button { create = true } label: { Image(systemName:"plus") }.accessibilityLabel("新建记录库") } }
                .refreshable { await store.refresh() }.safeAreaInset(edge:.top,spacing:0) { ConnectionBanner() }
                .sheet(isPresented:$create) { LibraryEditor(existing:nil) }
        }
    }
}
struct LibraryTableView: View {
    @EnvironmentObject var store: DeskStore
    let libraryID: Int
    @State private var query = ""
    @State private var viewID = ""
    @State private var showArchived = false
    @State private var newRecord = false
    @State private var settings = false
    @State private var importing = false
    var lib: RecordLibrary? { store.snapshot.libraries?.first { $0.id == libraryID } }
    var rows: [LedgerRecord] {
        guard let lib else { return [] }
        let view = lib.views.first { $0.id == viewID }
        var result = (store.snapshot.records ?? []).filter { $0.libraryId == libraryID && (showArchived || !$0.archived) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) && (view?.filters ?? []).allSatisfy($0.matches) }
        for sort in (view?.sorts ?? []).reversed() {
            result.sort { a,b in
                let x = a.value(sort.fieldId), y = b.value(sort.fieldId)
                if x == .null || x.text.isEmpty { return false }; if y == .null || y.text.isEmpty { return true }
                if case .int(let xv) = x, case .int(let yv) = y { return sort.descending ? xv > yv : xv < yv }
                return sort.descending ? x.text > y.text : x.text < y.text
            }
        }
        return result
    }
    var body: some View {
        ScrollView {
            if let lib {
                VStack(alignment:.leading,spacing:16) {
                    HStack(spacing:12) {
                        if !lib.views.isEmpty {
                            Picker("视图",selection:$viewID) {
                                Text("全部记录").tag("")
                                ForEach(lib.views) { Text($0.name).tag($0.id) }
                            }.pickerStyle(.menu).tint(.primary)
                        }
                        Spacer(minLength:0)
                        if showArchived { Tag(text:"含归档",symbol:"archivebox") }
                        Text("\(rows.count) 条记录").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Panel {
                        ScrollView(.horizontal) {
                            VStack(alignment:.leading,spacing:0) {
                                HStack(spacing:16) {
                                    Text("名称").frame(width:180,alignment:.leading)
                                    ForEach(lib.fields) { Text($0.name).frame(width:140,alignment:.leading) }
                                }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.vertical,10).padding(.horizontal,2)
                                Divider()
                                ForEach(rows) { row in
                                    NavigationLink { RecordPageView(recordID:row.id) } label: {
                                        HStack(spacing:16) {
                                            Text(row.title).font(.subheadline.weight(.medium))
                                                .frame(width:180,alignment:.leading).lineLimit(2)
                                                .foregroundStyle(.primary)
                                            ForEach(lib.fields) { f in
                                                Text(propertyText(row,f,store.snapshot)).font(.caption)
                                                    .frame(width:140,alignment:.leading).lineLimit(2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }.padding(.vertical,14).padding(.horizontal,2).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    Divider()
                                }
                            }
                        }
                    }
                    if rows.isEmpty { EmptyPanel(title:"这个视图没有记录",detail:"换个视图，或加入新的资料。",symbol:"doc.text") }
                }.padding(18)
            }
        }.background(DeskStyle.background).navigationTitle(lib?.name ?? "记录库").navigationBarTitleDisplayMode(.inline)
            .searchable(text:$query,prompt:"搜索记录名称").refreshable { await store.refresh() }
            .toolbar {
                ToolbarItemGroup(placement:.topBarTrailing) {
                    if let lib, store.snapshot.me.privileged || lib.workerAccess == "write" {
                        Button("新增记录",systemImage:"plus") { newRecord = true }
                    }
                    Menu {
                        Toggle("显示归档",isOn:$showArchived)
                        if store.snapshot.me.privileged {
                            Button("字段与视图",systemImage:"slider.horizontal.3") { settings = true }
                            Button("导入 CSV / JSON",systemImage:"square.and.arrow.down") { importing = true }
                        }
                    } label: { Image(systemName:"ellipsis.circle") }
                }
            }
            .sheet(isPresented:$newRecord) { if let lib { RecordEditor(library:lib,existing:nil) } }
            .sheet(isPresented:$settings) { if let lib { LibraryEditor(existing:lib) } }
            .sheet(isPresented:$importing) { if let lib { LedgerImportSheet(library:lib) } }
    }
}
private func propertyText(_ row: LedgerRecord, _ field: LedgerField, _ snapshot: Snapshot) -> String {
    let value = row.values[field.id] ?? .null
    if field.type == "rating", case .int(let n) = value { return n > 0 ? String(repeating:"★",count:min(5,n)) : "未评分" }
    if field.type == "member", !value.text.isEmpty { return snapshot.memberName(value.text) }
    return value.text.isEmpty ? "—" : value.text
}
struct RecordPageView: View {
    @EnvironmentObject var store: DeskStore
    let recordID: Int
    @State private var edit = false
    var record: LedgerRecord? { store.snapshot.records?.first { $0.id == recordID } }
    var lib: RecordLibrary? { store.snapshot.libraries?.first { $0.id == record?.libraryId } }
    var body: some View {
        ScrollView {
            if let record, let lib {
                VStack(alignment:.leading,spacing:16) {
                    VStack(alignment:.leading,spacing:8) {
                        Text(lib.name).font(.caption).foregroundStyle(.secondary)
                        Text(record.title).font(.title.weight(.semibold))
                            .frame(maxWidth:.infinity,alignment:.leading)
                        if record.archived { Tag(text:"已归档") }
                    }.padding(.vertical,6)
                    Panel {
                        VStack(alignment:.leading,spacing:14) {
                            SectionTitle(title:"正文")
                            if record.body.isEmpty { Text("暂无正文").font(.subheadline).foregroundStyle(.secondary) }
                            else { MarkdownPage(text:record.body) }
                        }
                    }
                    Panel {
                        DisclosureGroup {
                            VStack(spacing:14) {
                                ForEach(lib.fields) { f in
                                    if f.type == "url", let url = DeskStyle.link(record.values[f.id]?.text ?? "") {
                                        LabeledContent(f.name) { Link("打开链接",destination:url) }
                                    } else { LabeledContent(f.name,value:propertyText(record,f,store.snapshot)) }
                                }
                            }.font(.subheadline).padding(.top,14)
                        } label: {
                            HStack {
                                Text("属性").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Spacer()
                                Text("\(lib.fields.count) 项").font(.caption).foregroundStyle(.secondary)
                            }
                        }.tint(.secondary)
                    }
                    if !record.taskIds.isEmpty {
                        Panel {
                            VStack(alignment:.leading,spacing:14) {
                                SectionTitle(title:"关联任务")
                                ForEach(record.taskIds,id:\.self) { tid in
                                    NavigationLink { TaskDetailView(taskID:tid) } label: {
                                        HStack {
                                            Label(store.snapshot.tasks.first { $0.id == tid }?.title ?? tid,systemImage:"checklist")
                                                .font(.subheadline).foregroundStyle(.primary)
                                            Spacer(minLength:8)
                                            Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    Panel {
                        DisclosureGroup("修改历史与登记信息") {
                            VStack(alignment:.leading,spacing:18) {
                                Text("记录 #\(record.id) · 版本 \(record.version)\n由 \(store.snapshot.memberName(record.createdBy)) 建立于 \(DeskDate.display(record.createdAt))")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach((store.snapshot.recordEvents ?? []).filter { $0.recordId == record.id }) { e in
                                    VStack(alignment:.leading,spacing:8) {
                                        TimelineRow(title:"\(e.actorName) · \(e.kind)",bodyText:"属性、正文与关联变更均已保留。",time:e.timestamp)
                                        DisclosureGroup("查看此版本正文") {
                                            if case .object(let obj) = e.after, case .string(let page) = obj["body"] {
                                                Text(page).font(.caption).textSelection(.enabled)
                                            }
                                        }
                                    }
                                }
                            }.padding(.top,14)
                        }.font(.subheadline).tint(.secondary)
                    }
                }.padding(18)
            } else { EmptyPanel(title:"记录不在当前范围",detail:"可能已转派或权限变更，请刷新。",symbol:"doc.text").padding(18) }
        }
            .background(DeskStyle.background).navigationTitle("记录详情").navigationBarTitleDisplayMode(.inline)
            .toolbar { if let lib, store.snapshot.me.privileged || lib.workerAccess == "write" { Button("编辑") { edit = true } } }
            .sheet(isPresented:$edit) { if let record,let lib { RecordEditor(library:lib,existing:record) } }
            .refreshable { await store.refresh() }
    }
}
struct MarkdownPage: View {
    let text: String
    var body: some View { VStack(alignment:.leading,spacing:10) { ForEach(Array(text.components(separatedBy:"\n").enumerated()),id:\.offset) { _,line in
        if line.hasPrefix("### ") { Text(String(line.dropFirst(4))).font(.headline) }
        else if line.hasPrefix("## ") { Text(String(line.dropFirst(3))).font(.title3.weight(.semibold)) }
        else if line.hasPrefix("# ") { Text(String(line.dropFirst(2))).font(.title2.weight(.bold)) }
        else if line == "---" { Divider() }
        else { Text((try? AttributedString(markdown:line)) ?? AttributedString(line)).font(.subheadline) }
    } }.frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled) }
}
struct RecordEditor: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) var dismiss
    let library: RecordLibrary
    let existing: LedgerRecord?
    @State private var title = ""
    @State private var bodyText = ""
    @State private var values: [String:JSONValue] = [:]
    @State private var tasks: Set<String> = []
    @State private var archived = false
    @State private var preview = false
    private func text(_ id: String) -> Binding<String> { Binding(get:{ values[id]?.text ?? "" },set:{ values[id] = $0.isEmpty ? .null : .string($0) }) }
    var body: some View {
        NavigationStack { Form {
            Section("名称") { TextField("记录名称",text:$title,axis:.vertical) }
            Section("属性") { ForEach(library.fields) { f in
                if f.type == "rating" { Picker(f.name,selection:Binding(get:{ if case .int(let n) = values[f.id] { return n }; return -1 },set:{ values[f.id] = $0 < 0 ? .null : .int($0) })) { Text("未填写").tag(-1); ForEach(0...5,id:\.self) { Text($0 == 0 ? "0 星" : String(repeating:"★",count:$0)).tag($0) } } }
                else if ["select","status"].contains(f.type) { Picker(f.name,selection:text(f.id)) { Text("未填写").tag(""); ForEach(f.choices,id:\.self) { Text($0).tag($0) } } }
                else if f.type == "member" { Picker(f.name,selection:text(f.id)) { Text("未填写").tag(""); if let current=values[f.id]?.text,!current.isEmpty,!store.snapshot.members.contains(where:{ $0.id == current }) { Text(current).tag(current) }; ForEach(store.snapshot.members) { Text($0.name).tag($0.id) } } }
                else { TextField(f.type == "date" ? "\(f.name) · YYYY-MM-DD" : f.name,text:text(f.id),axis:.vertical).lineLimit(f.type == "longtext" ? 3...8 : 1...3).textInputAutocapitalization(f.type == "url" ? .never : .sentences) }
            } }
            Section("独立正文 · Markdown") { Toggle("预览排版",isOn:$preview); if preview { MarkdownPage(text:bodyText) } else { TextEditor(text:$bodyText).frame(minHeight:260) } }
            if store.snapshot.me.privileged || existing == nil { Section("关联任务") {
                ForEach(store.snapshot.tasks) { task in Toggle(task.title,isOn:Binding(get:{ tasks.contains(task.id) },set:{ if $0 { tasks.insert(task.id) } else { tasks.remove(task.id) } })) }
            } }
            if existing != nil { Section { Toggle("归档这条记录",isOn:$archived) } }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.navigationTitle(existing == nil ? "新增记录" : "编辑记录").navigationBarTitleDisplayMode(.inline)
            .onAppear { if let existing { title=existing.title; values=existing.values; bodyText=existing.body; tasks=Set(existing.taskIds); archived=existing.archived } }
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement:.confirmationAction) { Button("保存") { Task { if await store.saveRecord(library:library,existing:existing,title:title,values:values,body:bodyText,taskIds:tasks.sorted(),archived:archived) { dismiss() } } }.disabled(title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || store.isBusy || (!store.snapshot.me.privileged && existing == nil && tasks.isEmpty)) } }
        }
    }
}
struct LibraryEditor: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) var dismiss
    let existing: RecordLibrary?
    @State private var name = ""
    @State private var fields: [LedgerField] = []
    @State private var views: [LedgerViewDefinition] = []
    @State private var access = "write"
    @State private var editView: Int? = nil
    var body: some View {
        NavigationStack { Form {
            Section("记录库") { TextField("库名称",text:$name); Picker("关联任务的 Worker",selection:$access) { Text("可以读写").tag("write"); Text("只能阅读").tag("read") }; Text("Worker 仅看到与自己任务关联的记录，不是整个库。").font(.caption).foregroundStyle(.secondary) }
            if existing == nil { Section { Button("加入基础追踪字段") {
                fields = [LedgerField(id:"status",name:"状态",type:"status",options:["未开始","进行中","完成","已取消"]),LedgerField(id:"rating",name:"推荐度",type:"rating"),LedgerField(id:"date",name:"日期",type:"date"),LedgerField(id:"url",name:"链接",type:"url"),LedgerField(id:"owner",name:"所有者",type:"member"),LedgerField(id:"notes",name:"备注",type:"longtext")]
                views = [LedgerViewDefinition(id:"priority",name:"优先处理",filters:[LedgerFilter(fieldId:"status",op:"not_equals",value:.string("完成")),LedgerFilter(fieldId:"status",op:"not_equals",value:.string("已取消"))],sorts:[LedgerSort(fieldId:"rating",descending:true)])]
            } } }
            Section("自定义字段") {
                ForEach($fields) { $f in DisclosureGroup(f.name.isEmpty ? "新字段" : "\(f.name) · \(f.typeLabel)") {
                    TextField("字段名称",text:$f.name); Text(f.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Picker("类型",selection:$f.type) { ForEach(LedgerField.types,id:\.self) { k in Text(LedgerField(id:"",name:"",type:k).typeLabel).tag(k) } }
                    if ["select","status"].contains(f.type) { TextField("选项 · 用逗号分隔",text:Binding(get:{ f.choices.joined(separator:",") },set:{ f.options = $0.components(separatedBy:CharacterSet(charactersIn:",，")).map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty } }),axis:.vertical) }
                    Button("移除字段",role:.destructive) { fields.removeAll { $0.id == f.id } }
                } }
                Button("添加字段") { fields.append(LedgerField(id:"f_"+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased().prefix(10),name:"新字段",type:"text")) }
            }
            Section("筛选与排序视图") {
                ForEach(Array(views.enumerated()),id:\.element.id) { index,v in Button(v.name) { editView=index } }
                Button("新增视图") { views.append(LedgerViewDefinition(id:"v_"+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased().prefix(10),name:"新视图")); editView=views.count-1 }
            }
            Section { Text("删除或改变已使用的字段会由服务端检查；不丢弃既有属性。公式和汇总暂不加入。").font(.caption).foregroundStyle(.secondary) }
            if let error=store.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.navigationTitle(existing == nil ? "新建记录库" : "字段与视图").navigationBarTitleDisplayMode(.inline)
            .onAppear { if let existing { name=existing.name; fields=existing.fields; views=existing.views; access=existing.workerAccess } }
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement:.confirmationAction) { Button("保存") { Task { if await store.saveLibrary(existing:existing,name:name,fields:fields,views:views,workerAccess:access) { dismiss() } } }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || fields.contains { $0.name.isEmpty } || store.isBusy) } }
            .sheet(isPresented:Binding(get:{ editView != nil },set:{ if !$0 { editView=nil } })) { if let index=editView,views.indices.contains(index) { ViewRuleEditor(view:$views[index],fields:fields,remove:{ views.remove(at:index); editView=nil }) } }
        }
    }
}
struct ViewRuleEditor: View {
    @Environment(\.dismiss) var dismiss
    @Binding var view: LedgerViewDefinition
    let fields: [LedgerField]
    let remove: () -> Void
    var options: [LedgerField] { [LedgerField(id:"title",name:"名称",type:"text"),LedgerField(id:"updatedAt",name:"更新时间",type:"date"),LedgerField(id:"createdAt",name:"建立时间",type:"date")] + fields }
    var body: some View {
        NavigationStack { Form {
            Section { TextField("视图名称",text:$view.name) }
            Section("筛选 · 所有条件同时满足") {
                ForEach((view.filters ?? []).indices,id:\.self) { i in VStack(alignment:.leading) {
                    Picker("字段",selection:Binding(get:{ view.filters![i].fieldId },set:{ view.filters?[i].fieldId=$0 })) { ForEach(options) { Text($0.name).tag($0.id) } }
                    Picker("条件",selection:Binding(get:{ view.filters![i].op },set:{ view.filters?[i].op=$0 })) { Text("等于").tag("equals"); Text("不等于").tag("not_equals"); Text("包含").tag("contains"); Text("大于等于").tag("gte"); Text("小于等于").tag("lte"); Text("为空").tag("is_empty") }
                    if view.filters?[i].op != "is_empty" { TextField("比较值",text:Binding(get:{ view.filters?[i].value?.text ?? "" },set:{ text in let numeric=fields.first { $0.id == view.filters?[i].fieldId }?.type == "rating"; view.filters?[i].value = numeric ? Int(text).map(JSONValue.int) : .string(text) })) }
                    Button("移除条件",role:.destructive) { view.filters?.remove(at:i) }
                } }
                Button("添加筛选") { view.filters = (view.filters ?? []) + [LedgerFilter(fieldId:"title",op:"contains",value:.string(""))] }
            }
            Section("排序 · 从上到下优先") {
                ForEach((view.sorts ?? []).indices,id:\.self) { i in
                    Picker("字段",selection:Binding(get:{ view.sorts![i].fieldId },set:{ view.sorts?[i].fieldId=$0 })) { ForEach(options) { Text($0.name).tag($0.id) } }
                    Toggle("降序",isOn:Binding(get:{ view.sorts![i].descending },set:{ view.sorts?[i].descending=$0 }))
                    Button("移除此排序",role:.destructive) { view.sorts?.remove(at:i) }
                }
                Button("添加排序") { view.sorts = (view.sorts ?? []) + [LedgerSort(fieldId:"title")] }
            }
            Section { Button("移除此视图",role:.destructive) { remove(); dismiss() } }
        }.navigationTitle("视图规则").toolbar { Button("完成") { dismiss() } } }
    }
}
struct LedgerImportSheet: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) var dismiss
    let library: RecordLibrary
    @State private var format="csv"
    @State private var content=""
    @State private var file=false
    var body: some View {
        NavigationStack { Form {
            Section { Text("\(library.name) · 批量导入").font(.headline); Picker("格式",selection:$format) { Text("CSV").tag("csv"); Text("JSON").tag("json") }; Button("选择文件") { file=true } }
            Section("文件内容 · 确认后才写入") { TextEditor(text:$content).frame(minHeight:260).font(.system(.caption,design:.monospaced)) }
            Section { Text("每批 1–100 条，UTF-8，总请求最多 64 KB；超出请分批。CSV 表头 title 为名称，body 为正文，taskIds 用分号分隔，其余用字段 ID。JSON 为包含 title、values、body、taskIds 的对象数组。任何一行错误时整批回滚。").font(.caption).foregroundStyle(.secondary)
                Text(library.fields.map { "\($0.id)：\($0.name)" }.joined(separator:"\n")).font(.caption.monospaced()) }
            if let error=store.error { Text(error).foregroundStyle(.red).font(.caption) }
        }.navigationTitle("导入记录").toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement:.confirmationAction) { Button("确认导入") { Task { if await store.importRecords(library:library,format:format,content:content) { dismiss() } } }.disabled(store.isBusy || content.isEmpty ) } }
            .fileImporter(isPresented:$file,allowedContentTypes:[.commaSeparatedText,.json,.plainText]) { result in
                do { let url=try result.get(); let allowed=url.startAccessingSecurityScopedResource(); defer { if allowed { url.stopAccessingSecurityScopedResource() } }; let data=try Data(contentsOf:url); guard data.count<60000,let text=String(data:data,encoding:.utf8) else { throw DeskError(message:"请选择小于 60 KB 的 UTF-8 文件") }; content=text; format=url.pathExtension.lowercased()=="json" ? "json" : "csv" }
                catch { store.error=error.localizedDescription }
            }
        }
    }
}
