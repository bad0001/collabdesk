import Foundation

struct ImportedRecord: Codable { var title:String; var values:[String:JSONValue]?; var body:String?; var taskIds:[String]? }

enum LedgerValidation {
    static func values(_ values:[String:JSONValue], fields:[LedgerField], members:[Member], strictMembers:Bool = true) throws {
        guard Set(values.keys).isSubset(of:Set(fields.map(\.id))) else { throw DeskError(message:"属性含未知字段；先处理旧属性再移除字段。") }
        for f in fields {
            let v=values[f.id] ?? .null
            if v == .null || v == .string("") { continue }
            if f.type == "rating" { guard case .int(let n)=v, (0...5).contains(n) else { throw DeskError(message:"\(f.name) 应为 0–5 的整数") }; continue }
            guard case .string(let text)=v, text.count <= (f.type == "longtext" ? 20000 : 2000) else { throw DeskError(message:"\(f.name) 的类型或长度有误") }
            if ["select","status"].contains(f.type) && !f.choices.contains(text) { throw DeskError(message:"\(f.name) 的选项不存在") }
            if f.type == "url" && DeskStyle.link(text) == nil { throw DeskError(message:"\(f.name) 请填 HTTP(S) 链接") }
            if strictMembers && f.type == "member" && !members.contains(where:{ $0.id == text }) { throw DeskError(message:"成员属性需使用已登记的成员 ID") }
            if f.type == "date" {
                let df=DateFormatter(); df.locale=Locale(identifier:"en_US_POSIX"); df.timeZone=TimeZone(secondsFromGMT:0); df.dateFormat="yyyy-MM-dd"; df.isLenient=false
                guard let date=df.date(from:text),df.string(from:date)==text else { throw DeskError(message:"日期使用 YYYY-MM-DD") }
            }
        }
    }
    static func csv(_ text:String) throws -> [[String]] {
        let chars=Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        var rows:[[String]]=[],row:[String]=[],value="",quoted=false,closed=false,index=0
        while index<chars.count {
            let c=chars[index]
            if quoted {
                if c == "\"" { if index+1<chars.count && chars[index+1] == "\"" { value.append("\""); index+=1 } else { quoted=false; closed=true } }
                else { value.append(c) }
            } else if c == "\"" && value.isEmpty && !closed { quoted=true }
            else if c == "," { row.append(value); value=""; closed=false }
            else if c == "\n" || c == "\r" { row.append(value); if row.contains(where:{ !$0.isEmpty }) { rows.append(row) }; row=[]; value=""; closed=false; if c == "\r" && index+1<chars.count && chars[index+1] == "\n" { index+=1 } }
            else { guard !closed else { throw DeskError(message:"CSV 引号后应为逗号或换行") }; value.append(c) }
            index+=1
        }
        guard !quoted else { throw DeskError(message:"CSV 引号未闭合") }
        row.append(value); if row.contains(where:{ !$0.isEmpty }) { rows.append(row) }
        return rows
    }
    static func imported(_ content:String,format:String,library:RecordLibrary) throws -> [ImportedRecord] {
        guard content.utf8.count<60000 else { throw DeskError(message:"每批文件小于 60 KB") }
        let result:[ImportedRecord]
        if format == "json" { result=try JSONDecoder().decode([ImportedRecord].self,from:Data(content.utf8)) }
        else {
            let rows=try csv(content)
            guard let headers=rows.first,headers.contains("title"),Set(headers).count==headers.count,
                  Set(headers).isSubset(of:Set(library.fields.map(\.id)+["title","body","taskIds"])) else { throw DeskError(message:"CSV 表头需含 title，其余为字段 ID、body、taskIds") }
            result=try rows.dropFirst().map { row in
                guard row.count==headers.count else { throw DeskError(message:"CSV 行的列数不一致") }
                let data=Dictionary(uniqueKeysWithValues:zip(headers,row)); var props:[String:JSONValue]=[:]
                for f in library.fields { if let v=data[f.id] {
                    if v.isEmpty { props[f.id] = .null }
                    else if f.type == "rating" { guard let n=Int(v) else { throw DeskError(message:"评级请填 0–5 的整数") }; props[f.id] = .int(n) }
                    else { props[f.id] = .string(v) }
                } }
                return ImportedRecord(title:data["title"] ?? "",values:props,body:data["body"],taskIds:data["taskIds"]?.split(separator:";").map { $0.trimmingCharacters(in:.whitespaces) } ?? [])
            }
        }
        guard (1...100).contains(result.count) else { throw DeskError(message:"每批导入 1–100 条；超出请分批") }; return result
    }
}
