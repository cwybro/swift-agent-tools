import Foundation
import SwiftParser
import SwiftSyntax

/// A member whose body can be swapped at runtime with `@_dynamicReplacement`:
/// a function or a computed property (getter, optionally with a setter).
public struct ReplaceableMember: Equatable, Sendable {
  public enum Kind: String, Sendable { case function, property }
  public var kind: Kind
  /// Name used in `@_dynamicReplacement(for: …)`: `body`, `row(for:)`, `make(_:count:)`.
  public var selector: String
  /// The declaration with the body stripped; equal signatures mean the
  /// original symbol exists in the built module and can be replaced.
  public var signature: String
  /// Source of the replacement declaration, ready to drop into an extension.
  public var replacement: String
  /// Source of the member as written, used when it is new since the last
  /// full build and so cannot be a replacement.
  public var verbatim: String
}

/// One type (or extension) scope in a file.
public struct TypeScope: Equatable, Sendable {
  /// `Card`, `Outer.Inner`, `Array where Element == Int` is reduced to `Array`.
  public var path: String
  /// `struct`, `class`, `enum`, `actor`, `extension`, `protocol`.
  public var kind: String
  /// Everything a body-only change must leave alone: stored properties,
  /// initializers, cases, inheritance, generic parameters. A change here needs
  /// a full rebuild of the module.
  public var layout: String
  /// The full declaration (used when the whole type is new).
  public var verbatim: String
  public var members: [ReplaceableMember]
  /// The `#if` conditions this scope sits under, outermost first.
  public var conditions: [String]
  /// For extensions: the `where` clause, repeated on generated extensions.
  public var whereClause: String = ""
  /// The enclosing type path for nested types, nil at file scope.
  public var parentPath: String? = nil
  public var line: Int = 0
}

public struct PreviewDecl: Equatable, Sendable, Codable {
  public enum Kind: String, Codable, Sendable { case macro, provider }
  public var kind: Kind
  public var index: Int
  public var name: String?
  public var line: Int
  /// `#Preview` closure body statements (without `@Previewable` lines).
  public var body: String
  /// `@Previewable` declarations, hoisted into a wrapper view.
  public var previewables: [String]
  /// `PreviewProvider` type name for `.provider`.
  public var providerType: String?
  public var layout: PreviewLayout
  public var conditions: [String]

  public var displayName: String {
    if let name { return name }
    if let providerType { return providerType }
    return "Preview \(index + 1)"
  }
}

public enum PreviewLayout: Equatable, Sendable, Codable {
  case device
  case sizeThatFits
  case fixed(width: Double, height: Double)
}

public struct FileAnalysis: Sendable {
  public var path: String
  public var imports: [String]
  public var scopes: [TypeScope]
  public var globals: [ReplaceableMember]
  public var previews: [PreviewDecl]
  /// Top-level declarations that are neither types nor replaceable members
  /// (global stored `let`s, operators, typealiases…), part of the layout.
  public var otherTopLevel: [String]

  /// The parts of the file that must match the last full build for the file
  /// to hot reload.
  public func layoutKey(scope: TypeScope) -> String {
    scope.conditions.joined(separator: "&&") + "|" + scope.kind + " " + scope.path + "\n" + scope.layout
  }
}

public enum SourceAnalyzer {
  public static func analyze(path: String) throws -> FileAnalysis {
    let source = try String(contentsOfFile: path, encoding: .utf8)
    return analyze(source: source, path: path)
  }

  public static func analyze(source: String, path: String) -> FileAnalysis {
    let tree = Parser.parse(source: source)
    let visitor = Collector(converter: SourceLocationConverter(fileName: path, tree: tree), fileName: path)
    visitor.walkFile(tree)
    return FileAnalysis(
      path: path,
      imports: visitor.imports,
      scopes: visitor.scopes,
      globals: visitor.globals,
      previews: visitor.previews,
      otherTopLevel: visitor.otherTopLevel
    )
  }
}

// MARK: - Collector

private final class Collector {
  let converter: SourceLocationConverter
  var imports: [String] = []
  var scopes: [TypeScope] = []
  var globals: [ReplaceableMember] = []
  var previews: [PreviewDecl] = []
  var otherTopLevel: [String] = []

  let fileName: String
  init(converter: SourceLocationConverter, fileName: String) {
    self.converter = converter
    self.fileName = fileName
  }

  /// Line where the node's text (including leading trivia) begins.
  func rawLine(_ node: some SyntaxProtocol) -> Int {
    node.startLocation(converter: converter, afterLeadingTrivia: false).line
  }

  func line(_ node: some SyntaxProtocol) -> Int {
    node.startLocation(converter: converter, afterLeadingTrivia: true).line
  }

  func walkFile(_ file: SourceFileSyntax) {
    walkTopLevel(file.statements.map { Syntax($0.item) }, conditions: [])
  }

  func walkTopLevel(_ items: [Syntax], conditions: [String]) {
    for item in items {
      if let ifConfig = item.as(IfConfigDeclSyntax.self) {
        forEachClause(ifConfig) { clauseConds, elements in
          switch elements {
          case .statements(let stmts):
            walkTopLevel(stmts.map { Syntax($0.item) }, conditions: conditions + clauseConds)
          case .decls(let decls):
            walkTopLevel(decls.map { Syntax($0.decl) }, conditions: conditions + clauseConds)
          default:
            break
          }
        }
        continue
      }
      if let imp = item.as(ImportDeclSyntax.self) {
        imports.append(imp.trimmedDescription)
        continue
      }
      if let macro = item.as(MacroExpansionDeclSyntax.self), macro.macroName.text == "Preview" {
        addMacroPreview(arguments: macro.arguments, trailing: macro.trailingClosure, node: Syntax(macro), conditions: conditions)
        continue
      }
      if let macroExpr = item.as(MacroExpansionExprSyntax.self), macroExpr.macroName.text == "Preview" {
        addMacroPreview(arguments: macroExpr.arguments, trailing: macroExpr.trailingClosure, node: Syntax(macroExpr), conditions: conditions)
        continue
      }
      if let exprStmt = item.as(ExpressionStmtSyntax.self),
         let macroExpr = exprStmt.expression.as(MacroExpansionExprSyntax.self),
         macroExpr.macroName.text == "Preview" {
        addMacroPreview(arguments: macroExpr.arguments, trailing: macroExpr.trailingClosure, node: Syntax(macroExpr), conditions: conditions)
        continue
      }
      if let decl = item.as(DeclSyntax.self) {
        if handleTypeLike(decl, parentPath: nil, conditions: conditions) { continue }
        if let member = replaceable(decl, isTopLevel: true) {
          globals.append(member)
          continue
        }
        otherTopLevel.append(decl.trimmedDescription)
        continue
      }
      otherTopLevel.append(item.trimmedDescription)
    }
  }

  enum ClauseElements { case statements(CodeBlockItemListSyntax), decls(MemberBlockItemListSyntax), other }

  func forEachClause(_ ifConfig: IfConfigDeclSyntax, _ body: ([String], ClauseElements) -> Void) {
    var previous: [String] = []
    for clause in ifConfig.clauses {
      let keyword = clause.poundKeyword.text
      var conds: [String] = []
      if keyword == "#else" {
        conds = previous.map { "!(\($0))" }
      } else if let condition = clause.condition?.trimmedDescription {
        conds = previous.map { "!(\($0))" } + [condition]
        previous.append(condition)
      }
      switch clause.elements {
      case .statements(let s): body(conds, .statements(s))
      case .decls(let d): body(conds, .decls(d))
      default: body(conds, .other)
      }
    }
  }

  // MARK: Types

  /// Returns true if `decl` was a type or extension (and was recorded).
  func handleTypeLike(_ decl: DeclSyntax, parentPath: String?, conditions: [String]) -> Bool {
    let name: String
    let kind: String
    let memberBlock: MemberBlockSyntax
    var headerParts: [String] = []
    var isProvider = false

    if let s = decl.as(StructDeclSyntax.self) {
      name = s.name.text; kind = "struct"; memberBlock = s.memberBlock
      headerParts = [s.genericParameterClause?.trimmedDescription ?? "", s.inheritanceClause?.trimmedDescription ?? "", s.genericWhereClause?.trimmedDescription ?? ""]
      isProvider = inherits(s.inheritanceClause, "PreviewProvider")
    } else if let c = decl.as(ClassDeclSyntax.self) {
      name = c.name.text; kind = "class"; memberBlock = c.memberBlock
      headerParts = [c.genericParameterClause?.trimmedDescription ?? "", c.inheritanceClause?.trimmedDescription ?? "", c.genericWhereClause?.trimmedDescription ?? "", c.modifiers.trimmedDescription]
    } else if let e = decl.as(EnumDeclSyntax.self) {
      name = e.name.text; kind = "enum"; memberBlock = e.memberBlock
      headerParts = [e.genericParameterClause?.trimmedDescription ?? "", e.inheritanceClause?.trimmedDescription ?? "", e.genericWhereClause?.trimmedDescription ?? ""]
      isProvider = inherits(e.inheritanceClause, "PreviewProvider")
    } else if let a = decl.as(ActorDeclSyntax.self) {
      name = a.name.text; kind = "actor"; memberBlock = a.memberBlock
      headerParts = [a.genericParameterClause?.trimmedDescription ?? "", a.inheritanceClause?.trimmedDescription ?? "", a.genericWhereClause?.trimmedDescription ?? ""]
    } else if let x = decl.as(ExtensionDeclSyntax.self) {
      name = x.extendedType.trimmedDescription; kind = "extension"; memberBlock = x.memberBlock
      headerParts = [x.inheritanceClause?.trimmedDescription ?? "", x.genericWhereClause?.trimmedDescription ?? ""]
    } else if let p = decl.as(ProtocolDeclSyntax.self) {
      // Protocol requirements have no bodies; treat the whole protocol as layout.
      scopes.append(TypeScope(path: qualify(parentPath, p.name.text), kind: "protocol", layout: p.trimmedDescription, verbatim: p.trimmedDescription, members: [], conditions: conditions, parentPath: parentPath, line: line(p)))
      return true
    } else {
      return false
    }

    let path = qualify(parentPath, name)
    var whereClause = ""
    if let x = decl.as(ExtensionDeclSyntax.self) { whereClause = x.genericWhereClause?.trimmedDescription ?? "" }
    var layout: [String] = [headerParts.filter { !$0.isEmpty }.joined(separator: " ")]
    var members: [ReplaceableMember] = []

    // Extensions with conformances add witness tables: the conformance list is
    // layout, the bodies are not. Extensions without members are pure layout.
    // Reserve the scope's slot before its nested types are appended, so
    // outer scopes come first.
    let slot = scopes.count
    scopes.append(TypeScope(path: path, kind: kind, layout: "", verbatim: "", members: [], conditions: conditions))
    collectMembers(memberBlock.members, path: path, conditions: conditions, layout: &layout, members: &members)
    scopes[slot] = TypeScope(path: path, kind: kind, layout: layout.joined(separator: "\n"), verbatim: decl.trimmedDescription, members: members, conditions: conditions, whereClause: whereClause, parentPath: parentPath, line: line(decl))

    if isProvider {
      previews.append(PreviewDecl(kind: .provider, index: previews.count, name: nil, line: line(decl), body: "", previewables: [], providerType: path, layout: .device, conditions: conditions))
    }
    return true
  }

  func collectMembers(_ items: MemberBlockItemListSyntax, path: String, conditions: [String], layout: inout [String], members: inout [ReplaceableMember]) {
    for item in items {
      let decl = item.decl
      if let ifConfig = decl.as(IfConfigDeclSyntax.self) {
        // Members inside #if are recorded with the condition folded into the
        // layout key; replacements are wrapped back into the same #if.
        forEachClause(ifConfig) { clauseConds, elements in
          if case .decls(let decls) = elements {
            var innerMembers: [ReplaceableMember] = []
            var innerLayout: [String] = []
            collectMembers(decls, path: path, conditions: conditions + clauseConds, layout: &innerLayout, members: &innerMembers)
            let cond = clauseConds.joined(separator: " && ")
            layout.append(contentsOf: innerLayout.map { "#if \(cond): \($0)" })
            for var m in innerMembers {
              m.replacement = "#if \(cond)\n\(m.replacement)\n#endif"
              m.verbatim = "#if \(cond)\n\(m.verbatim)\n#endif"
              m.signature = "#if \(cond): \(m.signature)"
              members.append(m)
            }
          }
        }
        continue
      }
      // Nested types are scopes of their own; a new one hot reloads.
      if handleTypeLike(decl, parentPath: path, conditions: conditions) { continue }
      if let member = replaceable(decl, isTopLevel: false) {
        members.append(member)
        continue
      }
      // Stored properties, initializers, enum cases, subscripts, typealiases,
      // associated types, deinit, macro expansions: all layout.
      layout.append(decl.trimmedDescription)
    }
  }

  func inherits(_ clause: InheritanceClauseSyntax?, _ name: String) -> Bool {
    guard let clause else { return false }
    return clause.inheritedTypes.contains { t in
      let text = t.type.trimmedDescription
      return text == name || text.hasSuffix("." + name)
    }
  }

  func qualify(_ parent: String?, _ name: String) -> String {
    guard let parent else { return name }
    return parent + "." + name
  }

  // MARK: Members

  func replaceable(_ decl: DeclSyntax, isTopLevel: Bool) -> ReplaceableMember? {
    if let fn = decl.as(FunctionDeclSyntax.self) { return replaceableFunction(fn) }
    if let v = decl.as(VariableDeclSyntax.self) { return replaceableProperty(v) }
    return nil
  }

  /// Modifiers a replacement keeps: they change which symbol it replaces.
  static let keptModifiers: Set<String> = ["static", "class", "mutating", "nonmutating", "nonisolated", "consuming", "borrowing"]

  func keptModifiers(_ modifiers: DeclModifierListSyntax) -> String {
    let kept = modifiers.compactMap { m -> String? in
      let name = m.name.text
      guard Self.keptModifiers.contains(name) else { return nil }
      return m.trimmedDescription
    }
    return kept.joined(separator: " ")
  }

  func keptAttributes(_ attributes: AttributeListSyntax) -> String {
    attributes.compactMap { element -> String? in
      guard case .attribute(let attr) = element else { return nil }
      let name = attr.attributeName.trimmedDescription
      // Drop attributes that would conflict with or are irrelevant to a
      // private replacement.
      if ["objc", "IBAction", "IBOutlet", "inlinable", "usableFromInline", "_dynamicReplacement", "discardableResult", "available", "_disfavoredOverload", "_spi", "backDeployed", "preconcurrency"].contains(name) {
        return nil
      }
      return attr.trimmedDescription
    }.joined(separator: " ")
  }

  func sourceLocated(_ body: String, line: Int) -> String {
    let file = fileName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return "#sourceLocation(file: \"\(file)\", line: \(line))\n\(body)\n#sourceLocation()"
  }

  func replaceableFunction(_ fn: FunctionDeclSyntax) -> ReplaceableMember? {
    guard let body = fn.body else { return nil }
    // Operators cannot be dynamically replaced by name.
    if case .binaryOperator = fn.name.tokenKind { return nil }
    if case .prefixOperator = fn.name.tokenKind { return nil }
    if case .postfixOperator = fn.name.tokenKind { return nil }
    let name = fn.name.text
    let labels = fn.signature.parameterClause.parameters.map { p in p.firstName.text + ":" }.joined()
    let selector = "\(name)(\(labels))"
    let attrs = keptAttributes(fn.attributes)
    let mods = keptModifiers(fn.modifiers)
    let generics = fn.genericParameterClause?.trimmedDescription ?? ""
    let sig = fn.signature.trimmedDescription
    let whereClause = fn.genericWhereClause.map { " " + $0.trimmedDescription } ?? ""
    let bodyText = body.statements.description
    // The text starts at the statements' leading trivia (right after `{`).
    let bodyLine = rawLine(body.statements)
    let replacement = """
      @_dynamicReplacement(for: \(selector))
      \(attrs) private \(mods) func __preview__\(name)\(generics)\(sig)\(whereClause) {
      \(sourceLocated(bodyText, line: body.statements.isEmpty ? line(body) : bodyLine))
      }
      """
    let signature = "\(attrs) \(fn.modifiers.trimmedDescription) func \(name)\(generics)\(sig)\(whereClause)"
    return ReplaceableMember(kind: .function, selector: selector, signature: signature, replacement: replacement, verbatim: fn.trimmedDescription)
  }

  func replaceableProperty(_ v: VariableDeclSyntax) -> ReplaceableMember? {
    guard v.bindings.count == 1, let binding = v.bindings.first,
          let ident = binding.pattern.as(IdentifierPatternSyntax.self),
          let type = binding.typeAnnotation?.type,
          let accessorBlock = binding.accessorBlock,
          binding.initializer == nil
    else { return nil }
    if v.modifiers.contains(where: { $0.name.text == "lazy" }) { return nil }
    let name = ident.identifier.text
    let attrs = keptAttributes(v.attributes)
    let mods = keptModifiers(v.modifiers)
    var isViewBody = false
    var accessorsText: String
    var firstLine: Int
    switch accessorBlock.accessors {
    case .getter(let stmts):
      accessorsText = stmts.description
      firstLine = stmts.isEmpty ? line(accessorBlock) : rawLine(stmts)
      accessorsText = sourceLocated(accessorsText, line: firstLine)
    case .accessors(let list):
      // Observers mean a stored property: layout, not replaceable.
      if list.contains(where: { ["willSet", "didSet", "init"].contains($0.accessorSpecifier.text) }) { return nil }
      guard list.allSatisfy({ $0.body != nil }) else { return nil }
      accessorsText = list.map { acc -> String in
        let stmts = acc.body!.statements
        let l = stmts.isEmpty ? line(acc) : rawLine(stmts)
        let head = [acc.attributes.trimmedDescription, acc.modifier?.trimmedDescription ?? "", acc.accessorSpecifier.text, acc.parameters?.trimmedDescription ?? "", acc.effectSpecifiers?.trimmedDescription ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return "\(head) {\n\(sourceLocated(stmts.description, line: l))\n}"
      }.joined(separator: "\n")
    }
    // `var body: some View` gets its result builder from the View protocol
    // requirement; the replacement is not a witness so it must say so.
    let typeText = type.trimmedDescription
    if name == "body", typeText.hasPrefix("some "), !attrs.contains("Builder") {
      isViewBody = true
    }
    let builder = isViewBody ? "@ViewBuilder " : ""
    let replacement = """
      @_dynamicReplacement(for: \(name))
      \(builder)\(attrs) private \(mods) var __preview__\(name): \(typeText) {
      \(accessorsText)
      }
      """
    // The signature includes which accessors exist (get vs get/set).
    var accessorKinds = "get"
    if case .accessors(let list) = accessorBlock.accessors {
      accessorKinds = list.map { $0.accessorSpecifier.text }.sorted().joined(separator: ",")
    }
    let signature = "\(attrs) \(v.modifiers.trimmedDescription) var \(name): \(typeText) {\(accessorKinds)}"
    return ReplaceableMember(kind: .property, selector: name, signature: signature, replacement: replacement, verbatim: v.trimmedDescription)
  }

  // MARK: Previews

  func addMacroPreview(arguments: LabeledExprListSyntax, trailing: ClosureExprSyntax?, node: Syntax, conditions: [String]) {
    var name: String?
    var layout: PreviewLayout = .device
    var closure = trailing
    for arg in arguments {
      if arg.label == nil, let lit = arg.expression.as(StringLiteralExprSyntax.self) {
        name = lit.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
      } else if arg.label?.text == "traits" {
        layout = Self.parseLayout(arg.expression.trimmedDescription)
      } else if arg.label?.text == "body", let c = arg.expression.as(ClosureExprSyntax.self) {
        closure = c
      }
    }
    guard let closure else { return }
    var previewables: [String] = []
    var bodyLines: [String] = []
    for stmt in closure.statements {
      if let v = stmt.item.as(VariableDeclSyntax.self),
         v.attributes.contains(where: { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "Previewable" }) {
        let stripped = v.attributes.filter { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription != "Previewable" }
        previewables.append(v.with(\.attributes, stripped).trimmedDescription)
      } else {
        bodyLines.append(sourceLocated(stmt.trimmedDescription, line: line(stmt)))
      }
    }
    let previewIndex = previews.count
    previews.append(PreviewDecl(kind: .macro, index: previewIndex, name: name, line: line(node), body: bodyLines.joined(separator: "\n"), previewables: previewables, providerType: nil, layout: layout, conditions: conditions))
  }

  static func parseLayout(_ traits: String) -> PreviewLayout {
    if traits.contains("sizeThatFitsLayout") { return .sizeThatFits }
    if let range = traits.range(of: #"fixedLayout\(\s*width:\s*([0-9.]+)\s*,\s*height:\s*([0-9.]+)\s*\)"#, options: .regularExpression) {
      let numbers = traits[range].split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
      if numbers.count == 2 { return .fixed(width: numbers[0], height: numbers[1]) }
    }
    return .device
  }
}
