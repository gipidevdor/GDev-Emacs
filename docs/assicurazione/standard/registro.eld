;;; registro.eld --- Registro dei riferimenti normativi  -*- lisp-data -*-

;; Dati puri: si leggono con `read', non si valutano.  Ogni voce è una
;; plist.  Il registro contiene solo identificativi, edizione, stato,
;; licenza e provenienza.  Non contiene testo normativo.
;;
;; :classe-riuso
;;   aperto               testo ridistribuibile con attribuzione
;;   pubblico-da-verificare  documento di un ente pubblico: leggere la
;;                        dichiarazione di copyright prima di includerlo
;;                        (fuori dagli Stati Uniti il pubblico dominio
;;                        non è verificato)
;;   solo-riferimento     testo protetto: solo identificativi, numeri di
;;                        clausola e controlli operativi scritti da noi
;; :stato
;;   corrente, bozza, ritirata, da-verificare
;;
;; Verifica eseguita il 2026-11-17 su pagine ufficiali o su cataloghi
;; di vendita.  Dove le fonti divergono lo si dice in :note.

(
 (:id "iso-iec-ieee-12207"
  :titolo "Processi del ciclo di vita del software"
  :ente "ISO/IEC/IEEE"
  :edizione "2026" :ordine "seconda" :pubblicazione "2026-04"
  :sostituisce ("2017") :stato corrente :verificato "2026-11-17"
  :fonte "https://www.iso.org/standard/90219.html"
  :licenza "Copyright ISO/IEC/IEEE, acquisto a pagamento"
  :classe-riuso solo-riferimento
  :formati-ufficiali ("PDF")
  :note "L'edizione 2017 è ritirata. Il giorno di pubblicazione diverge fra IEEE (2026-04-15) e un altro catalogo (2026-04-29).")

 (:id "iso-iec-ieee-15289"
  :titolo "Contenuto dei prodotti d'informazione del ciclo di vita"
  :ente "ISO/IEC/IEEE"
  :edizione "2019" :ordine "quarta" :stato corrente :verificato "2026-11-17"
  :fonte "https://www.iso.org/standard/74909.html"
  :licenza "Copyright ISO/IEC/IEEE, acquisto a pagamento"
  :classe-riuso solo-riferimento
  :formati-ufficiali ("PDF")
  :note "Riesame confermato nel 2025 secondo la pagina ISO. Le edizioni 2015 e 2017 sono ritirate.")

 (:id "iso-iec-ieee-29148"
  :titolo "Ingegneria dei requisiti"
  :ente "ISO/IEC/IEEE"
  :edizione "2018" :stato corrente :verificato "2026-11-17"
  :fonte "https://standards.ieee.org/standard/29148-2018"
  :licenza "Copyright ISO/IEC/IEEE, acquisto a pagamento"
  :classe-riuso solo-riferimento
  :formati-ufficiali ("PDF")
  :note "Scheda IEEE attiva; nessuna edizione successiva trovata.")

 (:id "ieee-1012"
  :titolo "Verifica e validazione di sistemi, software e hardware"
  :ente "IEEE"
  :edizione "2024" :pubblicazione "2025-08-22" :stato corrente :verificato "2026-11-19"
  :fonte "https://standards.ieee.org/ieee/1012/7324/"
  :licenza "Copyright IEEE, acquisto a pagamento"
  :classe-riuso solo-riferimento
  :formati-ufficiali ("PDF")
  :note "Scheda ufficiale IEEE: Active Standard, approvata il 2024-11-12 e pubblicata il 2025-08-22. Solo riferimenti bibliografici e controlli originali GDev.")

 (:id "iso-iec-25010"
  :titolo "Modello della qualità di prodotto"
  :ente "ISO/IEC"
  :edizione "2023" :ordine "seconda" :pubblicazione "2023-11"
  :sostituisce ("2011") :stato corrente :verificato "2026-11-17"
  :fonte "https://www.iso.org/standard/78176.html"
  :licenza "Copyright ISO/IEC, acquisto a pagamento"
  :classe-riuso solo-riferimento
  :formati-ufficiali ("PDF")
  :note "La revisione 2023 cambia nomi e definizioni di alcune caratteristiche rispetto al 2011.")

 (:id "iso-iec-ieee-42010"
  :titolo "Descrizione dell'architettura"
  :ente "ISO/IEC/IEEE"
  :edizione "2022" :stato corrente :verificato "2026-11-19"
  :fonte "https://www.iso.org/standard/74393.html"
  :licenza "Copyright ISO/IEC/IEEE, acquisto a pagamento"
  :classe-riuso solo-riferimento
  :formati-ufficiali ("PDF")
  :note "Edizione 2 pubblicata nel novembre 2022, confermata sulla scheda ufficiale ISO. Nessuna clausola dedotta dalla sola scheda bibliografica.")

 (:id "iso-iec-33020"
  :titolo "Quadro di misurazione dei processi per la valutazione della capacità"
  :ente "ISO/IEC"
  :edizione "2019" :sostituisce ("2015") :stato corrente :verificato "2026-11-19"
  :fonte "https://www.iso.org/standard/78526.html"
  :licenza "Copyright ISO/IEC, acquisto a pagamento"
  :classe-riuso solo-riferimento
  :formati-ufficiali ("PDF")
  :note "Edizione confermata nel 2026 dalla scheda ISO. Riferimento metodologico: GDev non attribuisce livelli di capacità ISO.")

 (:id "iso-iec-3300x"
  :titolo "Serie 33001, 33002, 33003, 33004 sulla valutazione dei processi"
  :ente "ISO/IEC"
  :edizione "da-verificare" :stato da-verificare :verificato "2026-11-17"
  :fonte "https://www.iso.org/"
  :licenza "Copyright ISO/IEC, acquisto a pagamento"
  :classe-riuso solo-riferimento
  :formati-ufficiali ("PDF")
  :note "Voce di famiglia, non selezionabile come edizione. Usare iso-iec-33001, iso-iec-33002, iso-iec-33003 o iso-iec-33004, verificate separatamente.")

 (:id "ecss-e-st-40c"
  :titolo "Ingegneria spaziale: software"
  :ente "ECSS"
  :edizione "Rev.1" :pubblicazione "2025-04-30"
  :sostituisce ("2009-03-06") :stato corrente :verificato "2026-11-17"
  :fonte "https://ecss.nl/standard/ecss-e-st-40c-rev-1-software-30-april-2025"
  :licenza "Copyright ESA per i membri ECSS; riproduzione solo con consenso esplicito di ESA"
  :classe-riuso solo-riferimento
  :formato-gdev "ecss-e-st-40c-rev1-indice.eld"
  :formati-ufficiali ("PDF" "DOCX")
  :note "Conservare copie nel repository richiede il permesso scritto della segreteria ECSS. Le citazioni indicano riferimento esatto, versione e modifiche.")

 (:id "ecss-q-st-80c"
  :titolo "Assicurazione di prodotto: software"
  :ente "ECSS"
  :edizione "Rev.2" :pubblicazione "2025-04-30"
  :stato corrente :verificato "2026-11-17"
  :fonte "https://ecss.nl/standard/ecss-q-st-80c-rev-2-software-product-assurance-30-april-2025/"
  :licenza "Copyright ESA per i membri ECSS; riproduzione solo con consenso esplicito di ESA"
  :classe-riuso solo-riferimento
  :formato-gdev "ecss-q-st-80c-rev2-indice.eld"
  :formati-ufficiali ("PDF")
  :note "Stesse condizioni di ECSS-E-ST-40C.")

 (:id "ecss-s-st-00"
  :titolo "Sistema ECSS: descrizione, attuazione e requisiti generali"
  :ente "ECSS"
  :edizione "Rev.2" :pubblicazione "2025-11-21" :stato corrente :verificato "2026-11-19"
  :fonte "https://ecss.nl/standard/ecss-s-st-00c-rev-2-description-implementation-and-general-requirements-21-november-2025/"
  :licenza "Copyright ESA per i membri ECSS"
  :classe-riuso solo-riferimento
  :formato-gdev "ecss-s-st-00-rev2-indice.eld"
  :formati-ufficiali ("PDF")
  :note "Revisione 2 attiva, sostituisce Rev.1 del 15 giugno 2020. Identificativi delle clausole verificati nella fonte pubblica; nessun testo normativo conservato.")

 (:id "nasa-npr-7150-2"
  :titolo "Requisiti di ingegneria del software della NASA"
  :ente "NASA"
  :edizione "D" :validita ("2022-03-08" "2027-03-08")
  :stato corrente :verificato "2026-11-17"
  :fonte "https://nodis3.gsfc.nasa.gov/displayDir.cfm?Internal_ID=N_PR_7150_002D_&page_name=main"
  :licenza "Documento di ente federale statunitense: dichiarazione di copyright da leggere"
  :classe-riuso pubblico-da-verificare
  :formati-ufficiali ("PDF")
  :note "La validità scade il 2027-03-08: rivedere l'edizione prima di quella data.")

 (:id "nasa-std-8739-8"
  :titolo "Assicurazione e sicurezza del software della NASA"
  :ente "NASA"
  :edizione "B" :approvazione "2022-09-08" :stato corrente
  :verificato "2026-11-17"
  :fonte "https://standards.nasa.gov/standard/nasa/nasa-std-87398"
  :licenza "Documento di ente federale statunitense: dichiarazione di copyright da leggere"
  :classe-riuso pubblico-da-verificare
  :formati-ufficiali ("PDF")
  :note "Nessuna edizione successiva trovata.")

 (:id "nasa-hdbk-2203"
  :titolo "Manuale di ingegneria del software della NASA"
  :ente "NASA"
  :edizione "B" :approvazione "2020-04-20" :stato da-verificare
  :verificato "2026-11-17"
  :fonte "https://standards.nasa.gov/standard/NASA/NASA-HDBK-2203"
  :licenza "Documento di ente federale statunitense: dichiarazione di copyright da leggere"
  :classe-riuso pubblico-da-verificare
  :formati-ufficiali ("PDF" "wiki")
  :note "La scheda ufficiale del 2026-11-19 mostra versione d con data 2020-04-20, mentre il registro precedente riportava B. Edizione ambigua: non selezionabile finché risolta.")

 (:id "nist-sp-800-218"
  :titolo "Quadro di sviluppo software sicuro (SSDF)"
  :ente "NIST"
  :edizione "1.1" :pubblicazione "2022-02-03" :stato corrente
  :verificato "2026-11-17"
  :fonte "https://csrc.nist.gov/pubs/sp/800/218/final"
  :licenza "Il PDF dichiara che non è soggetto a copyright negli Stati Uniti; NIST dichiara copiabili le informazioni dei suoi siti, salvo il materiale marcato, e chiede l'indicazione della fonte"
  :classe-riuso aperto
  :formati-ufficiali ("PDF" "XLSX")
  :acquisizioni ((:file "fonti/nist-sp-800-218/nist.sp.800-218.ssdf-table.xlsx"
                  :url "https://csrc.nist.gov/files/pubs/sp/800/218/final/docs/nist.sp.800-218.ssdf-table.xlsx"
                  :data "2026-11-17" :byte 50039
                  :sha256 "f5729c4c6c792cbf6cfbea74eee7cc84c579b2109006fe3cbfa8934eb460bd55")
                 (:file "fonti/nist-sp-800-218/NIST.SP.800-218.pdf"
                  :url "https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-218.pdf"
                  :data "2026-11-17" :byte 739891
                  :sha256 "617746e553a9e2da49bfbd4eef0dfc3094758a39b869314e4173ac36605cde22"))
  :formato-gdev "nist-sp-800-218-v1.1.eld"
  :note "La Rev.1 (versione 1.2) è in bozza dal 2025-12-17, commenti chiusi il 2026-01-30. Una nota del 2026-05-20 la descrive ancora come bozza. Nessuna edizione finale trovata.")

 (:id "nist-sp-800-160-v1"
  :titolo "Ingegneria della sicurezza dei sistemi, volume 1"
  :ente "NIST"
  :edizione "Rev.1" :pubblicazione "2022-11" :stato corrente :verificato "2026-11-19"
  :fonte "https://csrc.nist.gov/pubs/sp/800/160/v1/r1/final"
  :licenza "Da verificare"
  :classe-riuso pubblico-da-verificare
  :formati-ufficiali ("PDF")
  :note "Edizione finale verificata sulla scheda NIST. Attuazione bibliografica senza riprodurre il testo.")

 (:id "nist-ir-8397"
  :titolo "Standard minimi per la verifica del software da parte degli sviluppatori"
  :ente "NIST"
  :edizione "2021" :stato corrente :verificato "2026-11-17"
  :fonte "https://csrc.nist.gov/pubs/ir/8397/final"
  :licenza "Il PDF cita il Titolo 17, sezione 105, del Codice degli Stati Uniti: non soggetto a copyright, pubblico dominio negli Stati Uniti"
  :classe-riuso aperto
  :formati-ufficiali ("PDF")
  :acquisizioni ((:file "fonti/nist-ir-8397/NIST.IR.8397.pdf"
                  :url "https://nvlpubs.nist.gov/nistpubs/ir/2021/NIST.IR.8397.pdf"
                  :data "2026-11-17" :byte 1575676
                  :sha256 "cadab12c1f7b1a6a8f844d19180381211e1c29d05554bd9efb277442d8fd983d"))
  :note "Rinvia alle pratiche SSDF.")

 (:id "owasp-asvs"
  :titolo "Standard di verifica della sicurezza delle applicazioni"
  :ente "OWASP"
  :edizione "5.0.0" :pubblicazione "2025-05" :stato corrente
  :verificato "2026-11-17"
  :fonte "https://github.com/OWASP/ASVS"
  :licenza "CC-BY-SA-4.0"
  :classe-riuso aperto
  :formati-ufficiali ("CSV" "DOCX" "PDF")
  :percorso-csv "5.0/docs_en/OWASP_Application_Security_Verification_Standard_5.0.0_en.csv"
  :acquisizioni ((:file "fonti/owasp-asvs/OWASP_Application_Security_Verification_Standard_5.0.0_en.csv"
                  :url "https://github.com/OWASP/ASVS/raw/v5.0.0/5.0/docs_en/OWASP_Application_Security_Verification_Standard_5.0.0_en.csv"
                  :data "2026-11-17" :byte 105100
                  :sha256 "98c8fe911b9edb403af8ee05d3ce8201ecac2659e313b053890a62847cdcf680"))
  :formato-gdev "owasp-asvs-5.0.0.eld"
  :note "Nessun JSON fra i file del tag v5.0.0. Attribuzione e condivisione alle stesse condizioni: tenere i derivati in file separati con avviso. Compatibilità con GPL-3.0-or-later da confermare con revisione legale.")

 (:id "slsa"
  :titolo "Livelli di fiducia della catena di fornitura del software"
  :ente "OpenSSF (SLSA)"
  :edizione "1.2" :pubblicazione "2025-11" :stato corrente
  :verificato "2026-11-18"
  :fonte "https://slsa.dev/spec/v1.2/"
  :licenza "Community Specification License 1.0; Apache-2.0 per parti preesistenti"
  :classe-riuso aperto
  :formati-ufficiali ("HTML" "Markdown")
  :revisione "ae7fc76215004e8fae250c877eff8919bf048e3b"
  :formato-gdev "slsa-1.2.eld"
  :acquisizioni ((:file "fonti/slsa/build-track-basics.md"
                  :url "https://raw.githubusercontent.com/slsa-framework/slsa/ae7fc76215004e8fae250c877eff8919bf048e3b/spec/build-track-basics.md"
                  :data "2026-11-18" :byte 6469
                  :sha256 "34b57d8975d02fde8519f857da3fb61bc184d110800d257e4228e0072547ff8f")
                 (:file "fonti/slsa/source-requirements.md"
                  :url "https://raw.githubusercontent.com/slsa-framework/slsa/ae7fc76215004e8fae250c877eff8919bf048e3b/spec/source-requirements.md"
                  :data "2026-11-18" :byte 32143
                  :sha256 "3b8a86e436b7dee18514923e8c0e959b28b922c2300aaad564a4dfb00094ae31")
                 (:file "fonti/slsa/Community-Specification-License-1.0.md"
                  :url "https://raw.githubusercontent.com/slsa-framework/governance/main/1._Community_Specification_License-v1.md"
                  :data "2026-11-18" :byte 16129
                  :sha256 "f40b1d00369c21b963293189b4617b5de439a11858541c07c620984634fb63b7")
                 (:file "fonti/slsa/Apache-2.0.txt"
                  :url "https://www.apache.org/licenses/LICENSE-2.0.txt"
                  :scaricato "2026-11-18" :byte 11358
                  :sha256 "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"))
  :note "Fonti Markdown della revisione fissata del ramo releases/v1.2; indice redazionale di otto livelli, senza attribuire livelli di conformità. Avvisi e licenza in fonti/slsa/NOTICE.md.")

 (:id "iso-iec-33001"
  :titolo "Concetti per la valutazione dei processi" :ente "ISO/IEC" :edizione "2015"
  :stato corrente :verificato "2026-11-19"
  :fonte "https://www.iso.org/standard/54175.html"
  :licenza "Copyright ISO/IEC; testo protetto non incluso"
  :classe-riuso solo-riferimento :formati-ufficiali ("PDF")
  :note "Scheda ISO: edizione confermata nel 2026. Controlli GDev originali; nessun livello ISO attribuito.")

 (:id "iso-iec-33002"
  :titolo "Conduzione della valutazione dei processi" :ente "ISO/IEC" :edizione "2015"
  :stato corrente :verificato "2026-11-19"
  :fonte "https://www.iso.org/standard/54176.html"
  :licenza "Copyright ISO/IEC; testo protetto non incluso"
  :classe-riuso solo-riferimento :formati-ufficiali ("PDF")
  :note "Scheda ISO: edizione confermata nel 2026. Controlli GDev originali; nessun livello ISO attribuito.")

 (:id "iso-iec-33003"
  :titolo "Definizione delle misure dei processi" :ente "ISO/IEC" :edizione "2015"
  :stato corrente :verificato "2026-11-19"
  :fonte "https://www.iso.org/standard/54177.html"
  :licenza "Copyright ISO/IEC; testo protetto non incluso"
  :classe-riuso solo-riferimento :formati-ufficiali ("PDF")
  :note "Scheda ISO: edizione confermata nel 2026. Controlli GDev originali; nessun livello ISO attribuito.")

 (:id "iso-iec-33004"
  :titolo "Modelli per la valutazione dei processi" :ente "ISO/IEC" :edizione "2015"
  :stato corrente :verificato "2026-11-19"
  :fonte "https://www.iso.org/standard/54178.html"
  :licenza "Copyright ISO/IEC; testo protetto non incluso"
  :classe-riuso solo-riferimento :formati-ufficiali ("PDF")
  :note "Scheda ISO: edizione confermata nel 2026. Controlli GDev originali; nessun livello ISO attribuito.")
)
