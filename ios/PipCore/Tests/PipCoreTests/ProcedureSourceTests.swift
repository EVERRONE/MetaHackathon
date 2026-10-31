import Foundation
import Testing
@testable import PipCore

/// Where a plan comes from, and what the user is told about it.
@Suite struct ProcedureSourceTests {
    static func raw(sources: [String]?) throws -> ProcedureCompiler.RawProcedure {
        let json = """
        {"title": "T", "classification": "allowed", "refusal_reason": "", "objects": [],
         "steps": [{"instruction": "Do it.", "why": "", "targets": [], "check_kind": "user", "expected": "done", "cautions": [], "gate": "", "source_ref": ""}],
         "cautions": [], "mismatch": ""\(sources.map { ", \"sources\": [" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" } ?? "")}
        """
        return try JSONDecoder().decode(ProcedureCompiler.RawProcedure.self, from: Data(json.utf8))
    }

    @Test func theWebToolIsForPagesAndForNoSource() {
        let pdf = ManualReference(title: "M", publisher: "P", url: "https://p.example/m.pdf")
        let page = ManualReference(title: "M", publisher: "P", url: "https://p.example/support", page: true)
        #expect(!ProcedureCompiler.searches(.manual(pdf)))
        #expect(ProcedureCompiler.searches(.manual(page)))
        #expect(ProcedureCompiler.searches(.none))
        #expect(!ProcedureCompiler.searches(.images([])))
    }

    @Test func aPlanFromTheWebShowsItsPagesButIsNotVerified() throws {
        let c = try Self.raw(sources: ["https://www.bosch-home.com/support", "not a link"]).compiled(goal: "g", source: .none, seconds: 1)
        #expect(c.procedure.source.kind == .web)
        #expect(c.procedure.source.reference == "https://www.bosch-home.com/support")
        #expect(!c.procedure.source.verified)
    }

    @Test func withoutPagesItIsGeneralKnowledge() throws {
        let c = try Self.raw(sources: []).compiled(goal: "g", source: .none, seconds: 1)
        #expect(c.procedure.source.kind == .none)
        let old = try Self.raw(sources: nil).compiled(goal: "g", source: .none, seconds: 1)
        #expect(old.procedure.source.kind == .none)
    }

    @Test func theManufacturersPageCountsAsVerified() throws {
        let page = ManualReference(title: "Support", publisher: "Philips", url: "https://www.philips.com/support", page: true)
        let c = try Self.raw(sources: []).compiled(goal: "g", source: .manual(page), seconds: 1)
        #expect(c.procedure.source.kind == .page)
        #expect(c.procedure.source.verified)
    }
}
