// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VerbinalKit

/// Direct coverage for `SimpleXML.nestedElements`, the primitive VOSpace
/// listing parsing relies on. `nestedElements` has two independent
/// implementations (macOS `XMLDocument`/XPath vs iOS `XMLParser`/SAX) with
/// documented behavioral differences; these tests pin the shared contract
/// (scoped child extraction, document order, namespace-prefix matching,
/// attribute extraction) and lock the platform-specific same-name-nesting
/// caveat so the divergence stays intentional.
final class SimpleXMLParserTests: XCTestCase {

    // MARK: - Scoped child extraction (the bug this primitive exists to prevent)

    /// A parent `<node>` with child `<property>` elements returns those
    /// properties scoped to the parent, in document order.
    func testNestedElements_returnsChildrenScopedToParentInDocumentOrder() {
        let xml = """
        <root>
          <node uri="vos://example/a">
            <property uri="#length">100</property>
            <property uri="#date">2026-01-01T00:00:00.000</property>
            <property uri="#type">text/plain</property>
          </node>
        </root>
        """

        let result = SimpleXML.nestedElements(
            parentLocalName: "node",
            childLocalName: "property",
            in: xml
        )

        XCTAssertEqual(result.count, 1)
        let children = result[0].children
        XCTAssertEqual(children.map(\.text), ["100", "2026-01-01T00:00:00.000", "text/plain"])
        XCTAssertEqual(children.map { $0.attributes["uri"] }, ["#length", "#date", "#type"])
    }

    /// Multiple parents, each with their own children: no cross-contamination.
    /// This is the exact regression VOSpace listings hit when a flat
    /// `elements(localName:)` query made every node share the LAST property
    /// value of each kind in the document.
    func testNestedElements_multipleParents_noCrossContamination() {
        let xml = """
        <root>
          <node uri="vos://example/a">
            <property uri="#length">100</property>
          </node>
          <node uri="vos://example/b">
            <property uri="#length">200</property>
          </node>
          <node uri="vos://example/c">
            <property uri="#length">300</property>
          </node>
        </root>
        """

        let result = SimpleXML.nestedElements(
            parentLocalName: "node",
            childLocalName: "property",
            in: xml
        )

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map { $0.parentAttributes["uri"] },
                       ["vos://example/a", "vos://example/b", "vos://example/c"])
        // Each parent keeps exactly its own single child — no leakage from siblings.
        XCTAssertEqual(result.map { $0.children.count }, [1, 1, 1])
        XCTAssertEqual(result.map { $0.children.first?.text }, ["100", "200", "300"])
    }

    /// A parent with no matching children yields an empty child set, not a
    /// borrowed one from a sibling.
    func testNestedElements_parentWithoutChildren_yieldsEmptyChildSet() {
        let xml = """
        <root>
          <node uri="vos://example/empty"></node>
          <node uri="vos://example/full">
            <property uri="#length">42</property>
          </node>
        </root>
        """

        let result = SimpleXML.nestedElements(
            parentLocalName: "node",
            childLocalName: "property",
            in: xml
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].children.isEmpty)
        XCTAssertEqual(result[1].children.count, 1)
        XCTAssertEqual(result[1].children.first?.text, "42")
    }

    // MARK: - Namespace-prefix handling (matches on local name)

    /// Namespace-prefixed elements (`vos:node`, `vos:property`) are matched on
    /// their local name. This mirrors real VOSpace container listings.
    func testNestedElements_namespacePrefixedElements_matchOnLocalName() {
        let xml = """
        <vos:nodes xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.0"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <vos:node uri="vos://cadc.nrc.ca~arc/home/user/file.fits"
                    xsi:type="vos:DataNode">
            <vos:properties>
              <vos:property uri="ivo://ivoa.net/vospace/core#length">5772</vos:property>
              <vos:property uri="ivo://ivoa.net/vospace/core#date">2026-05-29T12:00:00.000</vos:property>
            </vos:properties>
          </vos:node>
        </vos:nodes>
        """

        let result = SimpleXML.nestedElements(
            parentLocalName: "node",
            childLocalName: "property",
            in: xml
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].parentAttributes["uri"],
                       "vos://cadc.nrc.ca~arc/home/user/file.fits")
        let children = result[0].children
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0].attributes["uri"], "ivo://ivoa.net/vospace/core#length")
        XCTAssertEqual(children[0].text, "5772")
        XCTAssertEqual(children[1].attributes["uri"], "ivo://ivoa.net/vospace/core#date")
        XCTAssertEqual(children[1].text, "2026-05-29T12:00:00.000")
    }

    /// Two namespace-prefixed sibling nodes keep their own properties — the
    /// scoping that prevents every VOSpace node from showing the same
    /// size/last-modified.
    func testNestedElements_namespacePrefixedSiblings_noCrossContamination() {
        let xml = """
        <vos:nodes xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.0">
          <vos:node uri="vos://example/first">
            <vos:properties>
              <vos:property uri="#length">10</vos:property>
            </vos:properties>
          </vos:node>
          <vos:node uri="vos://example/second">
            <vos:properties>
              <vos:property uri="#length">20</vos:property>
            </vos:properties>
          </vos:node>
        </vos:nodes>
        """

        let result = SimpleXML.nestedElements(
            parentLocalName: "node",
            childLocalName: "property",
            in: xml
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].children.first?.text, "10")
        XCTAssertEqual(result[1].children.first?.text, "20")
    }

    // MARK: - Attribute extraction (parent + child)

    /// Attributes are extracted on both the parent element and each child,
    /// including the namespace-prefixed `xsi:type` attribute.
    func testNestedElements_extractsAttributesOnParentAndChildren() {
        let xml = """
        <vos:nodes xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.0"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <vos:node uri="vos://example/dir" xsi:type="vos:ContainerNode">
            <vos:properties>
              <vos:property uri="#ispublic" readOnly="true">true</vos:property>
            </vos:properties>
          </vos:node>
        </vos:nodes>
        """

        let result = SimpleXML.nestedElements(
            parentLocalName: "node",
            childLocalName: "property",
            in: xml
        )

        XCTAssertEqual(result.count, 1)
        let parentAttrs = result[0].parentAttributes
        XCTAssertEqual(parentAttrs["uri"], "vos://example/dir")
        XCTAssertEqual(parentAttrs["xsi:type"], "vos:ContainerNode")

        XCTAssertEqual(result[0].children.count, 1)
        let childAttrs = result[0].children[0].attributes
        XCTAssertEqual(childAttrs["uri"], "#ispublic")
        XCTAssertEqual(childAttrs["readOnly"], "true")
        XCTAssertEqual(result[0].children[0].text, "true")
    }

    // MARK: - Empty / malformed input

    func testNestedElements_emptyString_returnsEmpty() {
        XCTAssertTrue(
            SimpleXML.nestedElements(parentLocalName: "node", childLocalName: "property", in: "")
                .isEmpty
        )
    }

    func testNestedElements_noMatchingParent_returnsEmpty() {
        let xml = "<root><other uri=\"x\"><property uri=\"#length\">1</property></other></root>"
        XCTAssertTrue(
            SimpleXML.nestedElements(parentLocalName: "node", childLocalName: "property", in: xml)
                .isEmpty
        )
    }

    // MARK: - Documented platform divergence (same-name nesting of the child)

    // The two implementations diverge only on the unsupported case of a child
    // element nested inside another child of the same local name
    // (a `<property>` inside a `<property>`). These platform-conditional tests
    // lock the *documented* behavior on each path so the divergence stays
    // intentional rather than drifting silently.
    //
    // Source of truth: SimpleXML.nestedElements doc comment —
    //   "Same-name nesting of childLocalName ... is not supported; the iOS SAX
    //    path drops outer text accumulated past the inner close. The macOS
    //    XPath path returns the full descendant set in document order with no
    //    flattening."

    #if os(macOS)
    /// macOS (XMLDocument/XPath): a descendant `<property>` nested inside
    /// another `<property>` is returned as part of the full descendant set,
    /// in document order, with no flattening. The XPath `.//` axis matches
    /// both the outer and the inner element.
    func testNestedElements_sameNameNesting_macOSReturnsFullDescendantSet() {
        let xml = """
        <root>
          <node uri="vos://example/a">
            <property uri="#outer">outer-text<property uri="#inner">inner-text</property></property>
          </node>
        </root>
        """

        let result = SimpleXML.nestedElements(
            parentLocalName: "node",
            childLocalName: "property",
            in: xml
        )

        XCTAssertEqual(result.count, 1)
        let children = result[0].children
        // XPath returns the full descendant set: both outer and inner, in
        // document order. (The outer element's stringValue also includes the
        // inner text, since stringValue is the recursive text content.)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children.map { $0.attributes["uri"] }, ["#outer", "#inner"])
        XCTAssertEqual(children[1].text, "inner-text")
    }
    #endif

    #if os(iOS)
    /// iOS (XMLParser/SAX): same-name nesting is unsupported. The delegate
    /// only tracks one child at a time (`!inChild` guards re-entry), so the
    /// inner `<property>` is ignored and the inner close tag finalizes the
    /// single outer child. Outer text accumulated *past* the inner close is
    /// dropped because the child is finalized at the inner close. This test
    /// documents and locks that intentional caveat.
    func testNestedElements_sameNameNesting_iOSDropsOuterTextPastInnerClose() {
        let xml = """
        <root>
          <node uri="vos://example/a">
            <property uri="#outer">before<property uri="#inner">inner</property>after</property>
          </node>
        </root>
        """

        let result = SimpleXML.nestedElements(
            parentLocalName: "node",
            childLocalName: "property",
            in: xml
        )

        XCTAssertEqual(result.count, 1)
        let children = result[0].children
        // SAX collapses the nesting into a single child: the outer property is
        // opened, the inner open is ignored (already inChild), and the FIRST
        // closing `</property>` finalizes that single child. Text accumulated
        // after that inner close ("after") is dropped — the documented caveat.
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children[0].attributes["uri"], "#outer")
        XCTAssertFalse(children[0].text.contains("after"))
    }
    #endif
}
