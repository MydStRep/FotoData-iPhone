import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import PhotosUI

@main
struct FotoDataApp: App {
    var body: some Scene { WindowGroup { ReaderView() } }
}

struct Field: Identifiable {
    let id = UUID()
    let group: String
    let name: String
    let value: String
}

struct Photo {
    let bytes: Data
    let fields: [Field]
    init(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw CocoaError(.fileReadCorruptFile) }
        bytes = data
        let labels = ["Make":"Výrobce fotoaparátu","Model":"Model fotoaparátu","DateTimeOriginal":"Datum pořízení","PixelWidth":"Šířka (px)","PixelHeight":"Výška (px)","FNumber":"Clona","ExposureTime":"Doba expozice (s)","FocalLength":"Ohnisková vzdálenost (mm)","ISOSpeedRatings":"Citlivost ISO","LensModel":"Model objektivu","Software":"Použitý software","Orientation":"Orientace","Latitude":"Zeměpisná šířka","Longitude":"Zeměpisná délka"]
        var result = [Field(group:"Soubor", name:"Velikost", value:ByteCountFormatter.string(fromByteCount:Int64(data.count), countStyle:.file))]
        func collect(_ dict: NSDictionary, _ group: String) {
            for key in dict.allKeys.compactMap({ $0 as? String }).sorted() {
                guard let item = dict[key] else { continue }
                if let nested = item as? NSDictionary {
                    collect(nested, group + " / " + key.trimmingCharacters(in:CharacterSet(charactersIn:"{}")))
                } else {
                    let value: String
                    if let binary = item as? Data { value = binary.base64EncodedString() }
                    else if let array = item as? NSArray { value = array.map { String(describing:$0) }.joined(separator:", ") }
                    else { value = String(describing:item) }
                    result.append(Field(group:group,name:labels[key] ?? key,value:value))
                }
            }
        }
        if let props = CGImageSourceCopyProperties(source,nil) { collect(props as NSDictionary,"Soubor") }
        for i in 0..<CGImageSourceGetCount(source) {
            if let props = CGImageSourceCopyPropertiesAtIndex(source,i,nil) { collect(props as NSDictionary,"Snímek " + String(i+1)) }
            if let meta = CGImageSourceCopyMetadataAtIndex(source,i,nil) {
                CGImageMetadataEnumerateTagsUsingBlock(meta,nil,[kCGImageMetadataEnumerateRecursively:true] as CFDictionary) { path, tag in
                    if let value = CGImageMetadataTagCopyValue(tag) as? String {
                        result.append(Field(group:"XMP",name:path as String,value:value))
                    }
                    return true
                }
            }
        }
        let first = ["Datum pořízení","Výrobce fotoaparátu","Model fotoaparátu"]
        fields = result.sorted { (first.firstIndex(of:$0.name) ?? 3) < (first.firstIndex(of:$1.name) ?? 3) }
    }
}

struct ReaderView: View {
    @State private var photo: Photo?
    @State private var title = "FotoData"
    @State private var importing = false
    @State private var selection: PhotosPickerItem?
    @State private var query = ""
    @State private var page = 0
    @State private var tab = 0
    @State private var busy = false
    @State private var message = ""
    @State private var request = UUID()
    let accent = Color(red:0.06,green:0.39,blue:0.34)
    @MainActor func load(_ name: String, read: @escaping () async throws -> Data) {
        let id = UUID()
        request = id; busy = true; message = ""; photo = nil
        title = name; page = 0; tab = 0; query = ""
        Task {
            do {
                let data = try await read()
                let decoded = try await Task.detached(priority:.userInitiated) { try Photo(data) }.value
                if request == id { photo = decoded }
            } catch { if request == id { message = "Fotografii se nepodařilo přečíst. " + error.localizedDescription } }
            if request == id { busy = false }
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Label(title,systemImage:"camera.fill").font(.headline).lineLimit(1)
            HStack {
                PhotosPicker(selection:$selection,matching:.images,preferredItemEncoding:.current) { Label("Fotky",systemImage:"photo") }
                Button { importing = true } label: { Label("Soubory",systemImage:"folder") }
            }.buttonStyle(.borderedProminent)
            Picker("Zobrazení",selection:$tab) { Text("Údaje fotografie").tag(0); Text("Všechny bajty").tag(1) }.pickerStyle(.segmented)
            if busy { ProgressView("Čtu fotografii…") }
            if !message.isEmpty { Text(message) }
            if let photo = photo {
                if tab == 0 {
                    TextField("Hledat v údajích",text:$query).textFieldStyle(.roundedBorder)
                    List(photo.fields.filter { query.isEmpty || [$0.name,$0.value,$0.group].contains { $0.localizedCaseInsensitiveContains(query) } }) { row in
                        VStack(alignment:.leading,spacing:4) {
                            Text(row.group).font(.caption).foregroundColor(.secondary)
                            Text(row.name).font(.subheadline.bold())
                            Text(row.value).textSelection(.enabled)
                        }
                    }.listStyle(.plain)
                } else {
                    let last = max(0,(photo.bytes.count-1)/512)
                    HStack {
                        Button("Zpět") { page -= 1 }.disabled(page == 0)
                        Spacer(); Text("\(page+1) / \(last+1)").font(.caption); Spacer()
                        Button("Další") { page += 1 }.disabled(page >= last)
                    }
                    ScrollView([.horizontal,.vertical]) {
                        Text(dumpPage(photo.bytes)).font(.system(size:12,design:.monospaced)).textSelection(.enabled)
                    }
                }
            } else if !busy && message.isEmpty { Text("Vyber fotografii z galerie nebo ze Souborů.").foregroundColor(.secondary) }
            Spacer(minLength:0)
        }.padding().tint(accent)
        .onChange(of:selection) { item in
            guard let item = item else { return }
            load("Fotografie") {
                guard let data = try await item.loadTransferable(type:Data.self) else { throw CocoaError(.fileReadUnknown) }
                return data
            }
        }
        .fileImporter(isPresented:$importing,allowedContentTypes:[.image]) { result in
            if case let .success(url) = result {
                load(url.lastPathComponent) {
                    try await Task.detached {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        return try Data(contentsOf:url)
                    }.value
                }
            }
        }
    }
    func dumpPage(_ data: Data) -> String {
        let end = min(data.count,(page+1)*512)
        return stride(from:page*512,to:end,by:16).map { offset in
            let bytes = data[offset..<min(offset+16,end)]
            let hex = bytes.map { String(format:"%02X",$0) }.joined(separator:" ")
            let ascii = String(bytes.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return String(format:"%08X   ",offset) + hex.padding(toLength:47,withPad:" ",startingAt:0) + "   " + ascii
        }.joined(separator:"\n")
    }
}
