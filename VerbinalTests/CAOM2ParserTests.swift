// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class CAOM2ParserTests: XCTestCase {

    // MARK: - publisherID → observationURI conversion

    func testObservationURIFromPublisherIDStripsProductID() {
        let uri = CAOM2Observation.observationURI(
            fromPublisherID: "ivo://cadc.nrc.ca/CFHT?22803/22803o"
        )
        XCTAssertEqual(uri, "caom:CFHT/22803")
    }

    func testObservationURIFromPublisherIDWithoutProductID() {
        let uri = CAOM2Observation.observationURI(
            fromPublisherID: "ivo://cadc.nrc.ca/NEOSSAT?2026085000914"
        )
        XCTAssertEqual(uri, "caom:NEOSSAT/2026085000914")
    }

    func testObservationURIRejectsNonIVOAScheme() {
        XCTAssertNil(CAOM2Observation.observationURI(fromPublisherID: "https://example.com/x"))
        XCTAssertNil(CAOM2Observation.observationURI(fromPublisherID: ""))
        XCTAssertNil(CAOM2Observation.observationURI(fromPublisherID: "caom:CFHT/22803"))
    }

    // MARK: - Parser — minimal observation

    func testParseMinimalObservation() throws {
        let xml = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <caom2:Observation xmlns:caom2="http://www.opencadc.org/caom2/xml/v2.4" xsi:type="caom2:SimpleObservation" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <caom2:collection>CFHT</caom2:collection>
          <caom2:observationID>22803</caom2:observationID>
          <caom2:type>OBJECT</caom2:type>
          <caom2:intent>calibration</caom2:intent>
          <caom2:algorithm><caom2:name>exposure</caom2:name></caom2:algorithm>
          <caom2:telescope><caom2:name>CFHT 3.6m</caom2:name></caom2:telescope>
          <caom2:instrument><caom2:name>1872 RETICON</caom2:name></caom2:instrument>
          <caom2:planes>
            <caom2:plane>
              <caom2:productID>22803o</caom2:productID>
              <caom2:dataProductType>spectrum</caom2:dataProductType>
              <caom2:calibrationLevel>1</caom2:calibrationLevel>
            </caom2:plane>
          </caom2:planes>
        </caom2:Observation>
        """#
        let obs = try CAOM2Parser.parse(data: Data(xml.utf8))

        XCTAssertEqual(obs.collection, "CFHT")
        XCTAssertEqual(obs.observationID, "22803")
        XCTAssertEqual(obs.observationType, "OBJECT")
        XCTAssertEqual(obs.intent, "calibration")
        XCTAssertEqual(obs.algorithm, "exposure")
        XCTAssertEqual(obs.telescope?.name, "CFHT 3.6m")
        XCTAssertEqual(obs.instrument?.name, "1872 RETICON")
        XCTAssertEqual(obs.planes.count, 1)
        XCTAssertEqual(obs.planes.first?.productID, "22803o")
        XCTAssertEqual(obs.planes.first?.dataProductType, "spectrum")
        XCTAssertEqual(obs.planes.first?.calibrationLevel, 1)
    }

    func testParseMissingCollectionRaises() {
        let xml = #"""
        <?xml version="1.0"?>
        <caom2:Observation xmlns:caom2="http://www.opencadc.org/caom2/xml/v2.4">
          <caom2:observationID>x</caom2:observationID>
        </caom2:Observation>
        """#
        XCTAssertThrowsError(try CAOM2Parser.parse(data: Data(xml.utf8))) { err in
            guard case CAOM2ParserError.missingRequiredField(let field) = err else {
                XCTFail("Expected missingRequiredField, got \(err)"); return
            }
            XCTAssertEqual(field, "collection")
        }
    }

    func testParseMissingObservationIDRaises() {
        let xml = #"""
        <?xml version="1.0"?>
        <caom2:Observation xmlns:caom2="http://www.opencadc.org/caom2/xml/v2.4">
          <caom2:collection>CFHT</caom2:collection>
        </caom2:Observation>
        """#
        XCTAssertThrowsError(try CAOM2Parser.parse(data: Data(xml.utf8))) { err in
            guard case CAOM2ParserError.missingRequiredField(let field) = err else {
                XCTFail("Expected missingRequiredField, got \(err)"); return
            }
            XCTAssertEqual(field, "observationID")
        }
    }

    func testParseMalformedXMLRaises() {
        let xml = "this is not xml"
        XCTAssertThrowsError(try CAOM2Parser.parse(data: Data(xml.utf8))) { err in
            guard case CAOM2ParserError.malformedXML = err else {
                XCTFail("Expected malformedXML, got \(err)"); return
            }
        }
    }

    // MARK: - Parser — rich observation

    func testParseRichObservation() throws {
        // Synthetic fixture covering: target, proposal, environment, plane
        // with provenance + metrics + position polygon + energy + time +
        // polarization + artifacts.
        let xml = #"""
        <?xml version="1.0"?>
        <caom2:Observation xmlns:caom2="http://www.opencadc.org/caom2/xml/v2.4">
          <caom2:collection>JWST</caom2:collection>
          <caom2:observationID>jw01147</caom2:observationID>
          <caom2:metaRelease>2024-03-15T10:30:45.123</caom2:metaRelease>
          <caom2:proposal>
            <caom2:id>1147</caom2:id>
            <caom2:pi>Smith, J.</caom2:pi>
            <caom2:project>NIRCam Deep</caom2:project>
            <caom2:title>Deep imaging of M31</caom2:title>
            <caom2:keywords>
              <caom2:keyword>galaxy</caom2:keyword>
              <caom2:keyword>imaging</caom2:keyword>
            </caom2:keywords>
          </caom2:proposal>
          <caom2:target>
            <caom2:name>M31</caom2:name>
            <caom2:type>galaxy</caom2:type>
            <caom2:standard>false</caom2:standard>
            <caom2:redshift>-0.001</caom2:redshift>
            <caom2:moving>0</caom2:moving>
          </caom2:target>
          <caom2:telescope>
            <caom2:name>JWST</caom2:name>
            <caom2:geoLocationX>1.0</caom2:geoLocationX>
            <caom2:geoLocationY>2.0</caom2:geoLocationY>
            <caom2:geoLocationZ>3.0</caom2:geoLocationZ>
          </caom2:telescope>
          <caom2:instrument>
            <caom2:name>NIRCam</caom2:name>
          </caom2:instrument>
          <caom2:environment>
            <caom2:photometric>true</caom2:photometric>
            <caom2:ambientTemp>40.0</caom2:ambientTemp>
          </caom2:environment>
          <caom2:planes>
            <caom2:plane>
              <caom2:productID>nircam_f200w</caom2:productID>
              <caom2:dataProductType>image</caom2:dataProductType>
              <caom2:calibrationLevel>2</caom2:calibrationLevel>
              <caom2:dataRelease>2025-06-30T00:00:00</caom2:dataRelease>
              <caom2:provenance>
                <caom2:name>jwst_pipeline</caom2:name>
                <caom2:version>1.13.0</caom2:version>
                <caom2:producer>STScI</caom2:producer>
                <caom2:reference>https://jwst-pipeline.readthedocs.io/</caom2:reference>
              </caom2:provenance>
              <caom2:metrics>
                <caom2:sourceNumberDensity>1234.5</caom2:sourceNumberDensity>
                <caom2:magLimit>26.5</caom2:magLimit>
              </caom2:metrics>
              <caom2:quality><caom2:flag>good</caom2:flag></caom2:quality>
              <caom2:position>
                <caom2:bounds xsi:type="caom2:Polygon" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                  <caom2:Polygon>
                    <caom2:points>
                      <caom2:vertex><caom2:cval1>10.5</caom2:cval1><caom2:cval2>41.0</caom2:cval2></caom2:vertex>
                      <caom2:vertex><caom2:cval1>10.6</caom2:cval1><caom2:cval2>41.0</caom2:cval2></caom2:vertex>
                      <caom2:vertex><caom2:cval1>10.6</caom2:cval1><caom2:cval2>41.1</caom2:cval2></caom2:vertex>
                      <caom2:vertex><caom2:cval1>10.5</caom2:cval1><caom2:cval2>41.1</caom2:cval2></caom2:vertex>
                    </caom2:points>
                  </caom2:Polygon>
                </caom2:bounds>
                <caom2:dimension>
                  <caom2:naxis1>2048</caom2:naxis1>
                  <caom2:naxis2>2048</caom2:naxis2>
                </caom2:dimension>
              </caom2:position>
              <caom2:energy>
                <caom2:bounds>
                  <caom2:lower>1.755e-6</caom2:lower>
                  <caom2:upper>2.227e-6</caom2:upper>
                </caom2:bounds>
                <caom2:bandpassName>F200W</caom2:bandpassName>
                <caom2:emBand>Infrared</caom2:emBand>
              </caom2:energy>
              <caom2:time>
                <caom2:bounds>
                  <caom2:lower>59000.5</caom2:lower>
                  <caom2:upper>59000.55</caom2:upper>
                </caom2:bounds>
                <caom2:exposure>4320.0</caom2:exposure>
              </caom2:time>
              <caom2:polarization>
                <caom2:states>
                  <caom2:state>I</caom2:state>
                  <caom2:state>Q</caom2:state>
                </caom2:states>
              </caom2:polarization>
              <caom2:artifacts>
                <caom2:artifact>
                  <caom2:uri>cadc:JWST/jw01147_nircam_f200w_i2d.fits</caom2:uri>
                  <caom2:productType>science</caom2:productType>
                  <caom2:releaseType>data</caom2:releaseType>
                  <caom2:contentType>application/fits</caom2:contentType>
                  <caom2:contentLength>123456789</caom2:contentLength>
                  <caom2:contentChecksum>md5:abcdef</caom2:contentChecksum>
                </caom2:artifact>
                <caom2:artifact>
                  <caom2:uri>cadc:JWST/jw01147_nircam_f200w_preview.png</caom2:uri>
                  <caom2:productType>preview</caom2:productType>
                </caom2:artifact>
              </caom2:artifacts>
            </caom2:plane>
          </caom2:planes>
        </caom2:Observation>
        """#

        let obs = try CAOM2Parser.parse(data: Data(xml.utf8))

        // Top level
        XCTAssertEqual(obs.collection, "JWST")
        XCTAssertEqual(obs.observationID, "jw01147")
        XCTAssertNotNil(obs.metaRelease)

        // Proposal
        XCTAssertEqual(obs.proposal?.id, "1147")
        XCTAssertEqual(obs.proposal?.pi, "Smith, J.")
        XCTAssertEqual(obs.proposal?.title, "Deep imaging of M31")
        XCTAssertEqual(obs.proposal?.keywords, ["galaxy", "imaging"])

        // Target
        XCTAssertEqual(obs.target?.name, "M31")
        XCTAssertEqual(obs.target?.type, "galaxy")
        XCTAssertEqual(obs.target?.redshift, -0.001)
        XCTAssertEqual(obs.target?.moving, false)
        XCTAssertEqual(obs.target?.standard, false)

        // Telescope
        XCTAssertEqual(obs.telescope?.name, "JWST")
        XCTAssertEqual(obs.telescope?.geoLocation?.x, 1.0)

        // Environment
        XCTAssertEqual(obs.environment?.photometric, true)
        XCTAssertEqual(obs.environment?.ambientTemp, 40.0)

        // Plane
        XCTAssertEqual(obs.planes.count, 1)
        let plane = obs.planes[0]
        XCTAssertEqual(plane.productID, "nircam_f200w")
        XCTAssertEqual(plane.dataProductType, "image")
        XCTAssertEqual(plane.calibrationLevel, 2)
        XCTAssertEqual(plane.quality, "good")

        // Provenance
        XCTAssertEqual(plane.provenance?.name, "jwst_pipeline")
        XCTAssertEqual(plane.provenance?.version, "1.13.0")
        XCTAssertEqual(plane.provenance?.reference, "https://jwst-pipeline.readthedocs.io/")

        // Metrics
        XCTAssertEqual(plane.metrics?.magLimit, 26.5)
        XCTAssertEqual(plane.metrics?.sourceNumberDensity, 1234.5)

        // Position
        XCTAssertEqual(plane.position?.polygon.count, 4)
        XCTAssertEqual(plane.position?.polygon.first?.ra, 10.5)
        XCTAssertEqual(plane.position?.polygon.first?.dec, 41.0)
        XCTAssertEqual(plane.position?.dimensionPixels?.naxis1, 2048)
        XCTAssertEqual(plane.position?.dimensionPixels?.naxis2, 2048)

        // Energy
        XCTAssertEqual(plane.energy?.lowerMetres, 1.755e-6)
        XCTAssertEqual(plane.energy?.upperMetres, 2.227e-6)
        XCTAssertEqual(plane.energy?.bandpassName, "F200W")
        XCTAssertEqual(plane.energy?.emBand, "Infrared")

        // Time
        XCTAssertEqual(plane.time?.lowerMJD, 59000.5)
        XCTAssertEqual(plane.time?.upperMJD, 59000.55)
        XCTAssertEqual(plane.time?.exposureSeconds, 4320.0)

        // Polarization
        XCTAssertEqual(plane.polarization?.states, ["I", "Q"])

        // Artifacts
        XCTAssertEqual(plane.artifacts.count, 2)
        XCTAssertEqual(plane.artifacts[0].uri, "cadc:JWST/jw01147_nircam_f200w_i2d.fits")
        XCTAssertEqual(plane.artifacts[0].contentLength, 123_456_789)
        XCTAssertEqual(plane.artifacts[0].contentType, "application/fits")
        XCTAssertEqual(plane.artifacts[1].productType, "preview")
    }

    func testParseTolerantOfUnknownElements() throws {
        // Future schema additions should be ignored, not fail the parse.
        let xml = #"""
        <?xml version="1.0"?>
        <caom2:Observation xmlns:caom2="http://www.opencadc.org/caom2/xml/v2.4">
          <caom2:collection>X</caom2:collection>
          <caom2:observationID>y</caom2:observationID>
          <caom2:newFieldFromFutureSchema>ignored</caom2:newFieldFromFutureSchema>
        </caom2:Observation>
        """#
        let obs = try CAOM2Parser.parse(data: Data(xml.utf8))
        XCTAssertEqual(obs.collection, "X")
        XCTAssertEqual(obs.observationID, "y")
    }
}
