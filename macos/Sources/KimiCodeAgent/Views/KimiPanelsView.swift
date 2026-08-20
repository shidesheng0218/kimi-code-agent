import SwiftUI
import AppKit
import KimiAgentCore

/// Shared header for the workspace's secondary panes.
private struct KimiPaneHeader: View {
  let title: String
  let icon: String
  var trailing: String? = nil
  var refresh: (() -> Void)? = nil
  let back: () -> Void

  var body: some View {
    HStack {
      Label(title, systemImage: icon).font(.title3.weight(.semibold))
      Spacer()
      if let trailing {
        Text(trailing).font(.caption).foregroundStyle(KimiDesign.muted)
      }
      if let refresh {
        Button(action: refresh) { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless)
          .help("刷新")
      }
      Button("返回会话", action: back).buttonStyle(.bordered)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
  }
}

private struct KimiPaneEmpty: View {
  let icon: String
  let text: String

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: icon).font(.system(size: 36)).foregroundStyle(KimiDesign.primary)
      Text(text).foregroundStyle(KimiDesign.muted)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Diff 审阅

struct KimiDiffPane: View {
  @ObservedObject var model: KimiAppViewModel

  private var files: [FileDiff] { model.diffSnapshot?.files ?? [] }
  private var additions: Int { files.reduce(0) { $0 + $1.additions } }
  private var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

  var body: some View {
    VStack(spacing: 0) {
      KimiPaneHeader(
        title: "Diff 审阅",
        icon: "arrow.left.arrow.right",
        trailing: files.isEmpty ? nil : "\(files.count) 个文件 · +\(additions) −\(deletions)",
        refresh: { Task { await model.loadDiff() } },
        back: { model.show(.conversation) }
      )
      if model.diffLoading {
        ProgressView("正在计算工作区改动…").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if files.isEmpty {
        KimiPaneEmpty(icon: "checkmark.circle", text: "工作区没有未提交的改动。")
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(files) { file in
              KimiDiffFileCard(file: file)
            }
          }
          .padding(24)
        }
      }
    }
    .background(KimiDesign.background)
    .task { await model.loadDiff() }
  }
}

private struct KimiDiffFileCard: View {
  let file: FileDiff

  var body: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(file.hunks) { hunk in
          VStack(alignment: .leading, spacing: 0) {
            Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
              .font(.caption.monospaced())
              .foregroundStyle(KimiDesign.accent)
              .padding(.vertical, 4)
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
              Text(line.isEmpty ? " " : line)
                .font(.caption.monospaced())
                .foregroundStyle(color(for: line))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background(for: line))
                .textSelection(.enabled)
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 6))
        }
      }
      .padding(.top, 8)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: icon)
          .foregroundStyle(KimiDesign.primary)
        Text(file.path)
          .font(.subheadline.monospaced().weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        Text("+\(file.additions)").font(.caption).foregroundStyle(.green)
        Text("−\(file.deletions)").font(.caption).foregroundStyle(.red)
      }
    }
    .padding(12)
    .background(KimiDesign.surface)
    .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
  }

  private var icon: String {
    switch file.status {
    case .added: "doc.badge.plus"
    case .deleted: "doc.badge.minus"
    case .renamed: "doc.on.doc"
    case .modified: "doc.text"
    }
  }

  private func color(for line: String) -> Color {
    if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color(red: 0.10, green: 0.45, blue: 0.15) }
    if line.hasPrefix("-") && !line.hasPrefix("---") { return Color(red: 0.65, green: 0.15, blue: 0.15) }
    return KimiDesign.text
  }

  private func background(for line: String) -> Color {
    if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color.green.opacity(0.08) }
    if line.hasPrefix("-") && !line.hasPrefix("---") { return Color.red.opacity(0.08) }
    return .clear
  }
}

// MARK: - 项目文件

private struct KimiFileNode: Identifiable, Hashable {
  let url: URL
  let isDirectory: Bool
  var id: URL { url }

  var name: String { url.lastPathComponent }

  var children: [KimiFileNode]? {
    guard isDirectory else { return nil }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    let nodes = names
      .filter { !$0.hasPrefix(".") }
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
      .prefix(200)
      .map { name -> KimiFileNode in
        let child = url.appendingPathComponent(name)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir)
        return KimiFileNode(url: child, isDirectory: isDir.boolValue)
      }
    return nodes.sorted { ($0.isDirectory ? 0 : 1) < ($1.isDirectory ? 0 : 1) }
  }
}

struct KimiFilesPane: View {
  @ObservedObject var model: KimiAppViewModel
  @State private var selectedFile: URL?
  @State private var preview: String = ""

  private var root: KimiFileNode? {
    guard let path = model.activeProjectPath, !path.isEmpty else { return nil }
    return KimiFileNode(url: URL(fileURLWithPath: path, isDirectory: true), isDirectory: true)
  }

  var body: some View {
    VStack(spacing: 0) {
      KimiPaneHeader(
        title: "项目文件",
        icon: "folder",
        trailing: model.activeProjectPath,
        back: { model.show(.conversation) }
      )
      if let root {
        HSplitView {
          ScrollView {
            OutlineGroup(root.children ?? [], children: \.children) { node in
              HStack(spacing: 6) {
                Image(systemName: node.isDirectory ? "folder" : "doc.text")
                  .font(.caption)
                  .foregroundStyle(node.isDirectory ? KimiDesign.primary : KimiDesign.muted)
                Text(node.name)
                  .font(.subheadline)
                  .lineLimit(1)
              }
              .padding(.vertical, 2)
              .contentShape(Rectangle())
              .onTapGesture {
                guard !node.isDirectory else { return }
                selectedFile = node.url
                loadPreview(node.url)
              }
            }
            .padding(12)
          }
          .frame(minWidth: 220, maxWidth: 300)
          if selectedFile != nil {
            ScrollView {
              Text(preview)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .background(KimiDesign.surface)
          }
        }
      } else {
        KimiPaneEmpty(icon: "folder.badge.questionmark", text: "选择项目后将在这里显示文件。")
      }
    }
    .background(KimiDesign.background)
  }

  private func loadPreview(_ url: URL) {
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
      preview = "无法读取文件。"
      return
    }
    let capped = data.prefix(65_536)
    preview = String(data: capped, encoding: .utf8) ?? "（二进制文件，暂不支持预览）"
    if data.count > capped.count { preview += "\n\n…（已截断）" }
  }
}

// MARK: - 验证（Harness Intent/Receipt 审计）

struct KimiVerificationPane: View {
  @ObservedObject var model: KimiAppViewModel

  var body: some View {
    VStack(spacing: 0) {
      KimiPaneHeader(
        title: "验证与副作用回执",
        icon: "checkmark.seal",
        trailing: "\(model.verificationRecords.count) 条记录",
        refresh: { Task { await model.loadVerification() } },
        back: { model.show(.conversation) }
      )
      if model.verificationRecords.isEmpty {
        KimiPaneEmpty(icon: "checkmark.seal", text: "当前没有已记录的副作用回执。")
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(model.verificationRecords) { record in
              HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(for: record))
                  .foregroundStyle(color(for: record))
                  .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                  HStack {
                    Text(record.subject).font(.subheadline.weight(.medium))
                    Text(record.risk)
                      .font(.caption2)
                      .padding(.horizontal, 6)
                      .padding(.vertical, 2)
                      .background(KimiDesign.surfaceSecondary)
                      .clipShape(Capsule())
                  }
                  if let error = record.errorMessage, !error.isEmpty {
                    Text(error)
                      .font(.caption)
                      .foregroundStyle(.red)
                      .lineLimit(3)
                  }
                }
                Spacer()
                Text(record.outcome ?? "进行中")
                  .font(.caption)
                  .foregroundStyle(color(for: record))
              }
              .padding(12)
              .background(KimiDesign.surface)
              .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
            }
          }
          .padding(24)
        }
      }
    }
    .background(KimiDesign.background)
    .task { await model.loadVerification() }
  }

  private func icon(for record: KimiVerificationRecord) -> String {
    switch record.outcome {
    case "success": "checkmark.circle.fill"
    case "failure": "xmark.circle.fill"
    case "cancelled": "minus.circle.fill"
    default: "clock"
    }
  }

  private func color(for record: KimiVerificationRecord) -> Color {
    switch record.outcome {
    case "success": .green
    case "failure": .red
    case "cancelled": .orange
    default: KimiDesign.muted
    }
  }
}

// MARK: - 集成（MCP / Skills）

struct KimiIntegrationsPane: View {
  @ObservedObject var model: KimiAppViewModel

  var body: some View {
    VStack(spacing: 0) {
      KimiPaneHeader(
        title: "集成",
        icon: "puzzlepiece.extension",
        refresh: { Task { await model.loadIntegrations() } },
        back: { model.show(.conversation) }
      )
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 10) {
            Text("MCP 服务器").font(.headline)
            if model.integrationStatus.mcpServers.isEmpty {
              Text("未配置 MCP 服务器。可在引擎配置中添加后重启运行时。")
                .font(.subheadline)
                .foregroundStyle(KimiDesign.muted)
            } else {
              ForEach(model.integrationStatus.mcpServers) { server in
                HStack(spacing: 10) {
                  Circle()
                    .fill(server.status == "connected" ? Color.green : (server.status == "failed" ? Color.red : Color.orange))
                    .frame(width: 8, height: 8)
                  Text(server.name).font(.subheadline.weight(.medium))
                  Text(server.status).font(.caption).foregroundStyle(KimiDesign.muted)
                  Spacer()
                  if let detail = server.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.red).lineLimit(1)
                  }
                }
                .padding(12)
                .background(KimiDesign.surface)
                .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
              }
            }
          }
          VStack(alignment: .leading, spacing: 10) {
            Text("Skills").font(.headline)
            if model.integrationStatus.skills.isEmpty {
              Text("未发现技能。项目 .kimi/skills 或插件内的 SKILL.md 会被自动注册。")
                .font(.subheadline)
                .foregroundStyle(KimiDesign.muted)
            } else {
              ForEach(model.integrationStatus.skills) { skill in
                VStack(alignment: .leading, spacing: 3) {
                  Text(skill.name).font(.subheadline.weight(.medium))
                  if let description = skill.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(KimiDesign.muted)
                  }
                }
                .padding(12)
                .background(KimiDesign.surface)
                .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
              }
            }
          }
        }
        .padding(24)
      }
    }
    .background(KimiDesign.background)
    .task { await model.loadIntegrations() }
  }
}

// MARK: - Browser 产物

struct KimiBrowserPane: View {
  @ObservedObject var model: KimiAppViewModel

  private var imageArtifacts: [URL] {
    KimiArtifactImages.extract(from: model.state.activities.compactMap(\.detail))
  }

  private var browserActivities: [KimiActivity] {
    model.state.activities.filter {
      let title = $0.title.lowercased()
      return title.contains("browser") || title.contains("浏览器") || title.contains("kimi_browser")
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      KimiPaneHeader(
        title: "Browser 产物",
        icon: "safari",
        back: { model.show(.conversation) }
      )
      if imageArtifacts.isEmpty && browserActivities.isEmpty {
        KimiPaneEmpty(icon: "safari", text: "尚未发起浏览器验证。让 Kimi 验证一个网页后，截图与控制台产物会出现在这里。")
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(imageArtifacts, id: \.self) { url in
              if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                  .resizable()
                  .aspectRatio(contentMode: .fit)
                  .frame(maxWidth: 720)
                  .clipShape(RoundedRectangle(cornerRadius: 10))
                  .overlay(RoundedRectangle(cornerRadius: 10).stroke(KimiDesign.border, lineWidth: 1))
                Text(url.lastPathComponent)
                  .font(.caption2)
                  .foregroundStyle(KimiDesign.muted)
              }
            }
            ForEach(browserActivities) { activity in
              KimiActivityCard(activity: activity)
            }
          }
          .padding(24)
        }
      }
    }
    .background(KimiDesign.background)
  }
}
