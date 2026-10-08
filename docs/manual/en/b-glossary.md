# Glossary

| Term | Meaning |
|---|---|
| **ADQL** | Astronomical Data Query Language: the SQL-like language of the archive's TAP service. The **ADQL** tab of Search writes and runs it. |
| **Allocation** | The computing your CANFAR account may use: the cores, memory and GPUs of sessions, batch jobs and Remote Compute. |
| **Batch job** | A container on CANFAR that runs one command without a window, and ends. Also called a *headless* session. See [Batch jobs](07-batch-jobs.md). |
| **Blink** | Alternating two images in the same place, to see what changed. |
| **CADC** | The Canadian Astronomy Data Centre: the archive Verbinal searches, and the accounts it signs in with. |
| **Calibration level** | How processed a product is: 0 raw, in the instrument's own format; 1 raw, in a standard format such as FITS; 2 calibrated; 3 built from several, such as a stack or a mosaic; 4 an analysis product, such as a catalogue. **Cal. Level** in Search. |
| **CANFAR** | The Canadian Advanced Network for Astronomy Research: the science platform where sessions, batch jobs and Remote Compute run, and your VOSpace storage. |
| **CAOM-2** | The Common Archive Observation Model: how the CADC describes an observation, its planes (products) and their artifacts (files). |
| **CARTA** | The Cube Analysis and Rendering Tool for Astronomy, run as a CANFAR session. |
| **Collection** | The archive an observation belongs to: CFHT, HST, JWST, JCMT, GEMINI, … |
| **Contributed session** | A session whose image someone contributed to CANFAR, such as a web application. Remote Compute runs as one. |
| **Cube** | A FITS image with a third axis, usually wavelength or velocity: a spectrum at every pixel. See [Cube Viewer](05-cube-viewer.md). |
| **Cutout** | The part of a file you need, cut by the CADC before you download it (with its SODA service). |
| **DataLink** | The CADC service that lists an observation's files, previews and cutouts. |
| **Data train** | The lists under the Search form (band, collection, instrument, filter…) that narrow each other as you choose. |
| **DS9 regions** | The region file format of SAOImage DS9; Verbinal exports marks in it. |
| **Firefly** | A web viewer for astronomical data, run as a CANFAR session. |
| **FITS** | Flexible Image Transport System: the file format of astronomical images, cubes and tables. `.fz` files are FITS compressed with fpack. |
| **Harbor** | The software of CANFAR's image registry, `images.canfar.net`. Its **CLI secret** is the password for the registry. |
| **HDU** | Header Data Unit: one part of a FITS file, an image or a table with its header. A file can hold many. |
| **Image** (container) | What a CANFAR session or job runs: an operating system with its software, stored in a registry. |
| **IVOA** | The International Virtual Observatory Alliance, which defines TAP, DataLink, SODA, VOSpace and the registry of services. |
| **Mark** | Your annotation on an image or cube: a circle, box, callout or text, kept with the file. Not the same as a hint. |
| **MCP** | The Model Context Protocol, through which AI assistants such as Claude use Verbinal's tools. |
| **MJD** | Modified Julian Date: days since 17 November 1858, used for observation times. |
| **Notebook** | A Jupyter notebook: code, results and text in one document, run as a CANFAR session. |
| **Plane** | One product of an observation in CAOM-2, such as the raw data or a calibrated image. |
| **Probe** | The small batch job Image Discovery runs inside an image to list its packages. |
| **Publisher ID** | An observation plane's identifier at the CADC, such as `ivo://cadc.nrc.ca/HST?…`. |
| **Registry** | Two things: the IVOA registry, where Verbinal finds the CADC services; and a container registry, where images are kept. |
| **Resolver** | The service that turns a name (M31, a supernova) into a position: SIMBAD, NED or VizieR, through the CADC. |
| **Session** | An interactive container on CANFAR: a notebook, a desktop, CARTA, Firefly or a contributed application. |
| **Skaha** | The CANFAR service that runs sessions and batch jobs. |
| **SODA** | Server-side Operations for Data Access: the IVOA service the CADC cuts files with. |
| **Stretch** | How pixel values become brightness: linear, logarithmic, square root, squared or asinh. |
| **TAP** | Table Access Protocol: the IVOA service that answers ADQL queries. |
| **VizieR** | The catalogue service of the CDS in Strasbourg. |
| **VOSpace** | The IVOA standard for storage: your CANFAR storage. See [Storage](09-storage.md). |
| **WCS** | World Coordinate System: the header keywords that map pixels to sky positions and wavelengths. |
| **x1d** | An HST file holding a one-dimensional extracted spectrum, as a table. |
