// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin
//
// ─────────────────────────────────────────────────────────────────────────────
// ⚠️  TEMPLATE — NOT LEGAL ADVICE (applies to BOTH the English and French text).
//
// Engineering-drafted starting point so the acceptance gate is functional and
// bilingual. NOT reviewed by a lawyer or a legal translator. Before shipping,
// have qualified counsel review both languages for enforceability in your
// jurisdiction, and replace every [BRACKETED] placeholder. Bump `version` on any
// material change so all users are re-prompted to accept.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

/// The Terms of Use / disclaimer content, available in English and French, shown
/// by the first-launch acceptance gate and the in-app viewer. Self-contained
/// (does not rely on the String Catalog) so the legal copy and its translation
/// live and version together.
enum LegalText {

    /// Acceptance version. Bump on any material change (either language) to re-prompt.
    static let version = 1

    static let developer = "Serhii Zautkin"      // [confirm: individual vs. entity name]
    static let appName = "Verbinal"

    struct Section: Identifiable {
        let heading: String
        let body: String
        var id: String { heading }
    }

    /// A fully-localized Terms document plus the surrounding UI strings (so the
    /// gate, viewer, and About/Account links are localized from one place).
    struct Document {
        let title: String
        let lastUpdatedLine: String
        let intro: String
        let sections: [Section]
        // Surrounding UI
        let acceptHeadline: String
        let acceptSubhead: String
        let agreeToggle: String
        let agreeButton: String
        let quitButton: String
        let doneButton: String
        let copyButton: String
        let termsLink: String

        var plainText: String {
            var out = "\(title)\n\(lastUpdatedLine)\n\n\(intro)\n\n"
            for s in sections { out += "\(s.heading)\n\(s.body)\n\n" }
            return out
        }
    }

    /// Pick the document for the app's current locale (French for `fr`, else English).
    static func document(for locale: Locale) -> Document {
        (locale.language.languageCode?.identifier == "fr") ? french : english
    }

    // MARK: - English

    static let english = Document(
        title: "Terms of Use & Disclaimers",
        lastUpdatedLine: "Last updated: June 2, 2026",
        intro: """
        Please read these Terms of Use ("Terms") carefully before using \(appName) (the \
        "App"). By tapping "I Agree" — or by installing or using the App — you accept these \
        Terms. If you do not agree, do not use the App.
        """,
        sections: [
            Section(heading: "1. Acceptance & License", body: """
            \(appName) is provided by \(developer) ("we", "us"). Subject to these Terms, we \
            grant you a personal, non-exclusive, non-transferable, revocable license to use the \
            App on devices you own or control, for your own non-commercial or internal research \
            use. Where the App is obtained through Apple's App Store, Apple's Licensed \
            Application End User License Agreement also applies and, to the extent it conflicts \
            with these Terms, Apple's minimum terms govern that distribution.
            """),
            Section(heading: "2. No Warranty — Provided \u{201C}AS IS\u{201D}", body: """
            THE APP IS PROVIDED \u{201C}AS IS\u{201D} AND \u{201C}AS AVAILABLE\u{201D}, WITHOUT WARRANTY OF ANY KIND, \
            WHETHER EXPRESS, IMPLIED, OR STATUTORY. TO THE FULLEST EXTENT PERMITTED BY LAW, WE \
            DISCLAIM ALL WARRANTIES, INCLUDING THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS \
            FOR A PARTICULAR PURPOSE, TITLE, NON-INFRINGEMENT, AND ANY WARRANTY THAT THE APP WILL \
            BE UNINTERRUPTED, ERROR-FREE, SECURE, OR THAT DATA WILL BE ACCURATE, PRESERVED, OR \
            RECOVERABLE. You use the App at your own risk.
            """),
            Section(heading: "3. Your Data & Backups", body: """
            The App stores your content — including research notes, ratings, tags, saved \
            queries, downloaded files, and preferences — locally on your device. We do not \
            operate a backup or sync service for this content. Software can contain defects that \
            corrupt, overwrite, or delete data, and operating-system, hardware, or storage \
            failures can do the same. YOU ARE SOLELY RESPONSIBLE FOR MAINTAINING INDEPENDENT \
            BACKUPS of any data you value. Use the App's export feature and your own backup \
            system regularly. We are not responsible for any loss, corruption, or inaccessibility \
            of your data.
            """),
            Section(heading: "4. Limitation of Liability", body: """
            TO THE FULLEST EXTENT PERMITTED BY LAW, IN NO EVENT WILL WE BE LIABLE FOR ANY \
            INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, EXEMPLARY, OR PUNITIVE DAMAGES, OR FOR \
            ANY LOSS OF DATA, LOSS OF RESEARCH, LOST PROFITS, OR LOSS OF GOODWILL, ARISING OUT OF \
            OR RELATED TO YOUR USE OF (OR INABILITY TO USE) THE APP, EVEN IF ADVISED OF THE \
            POSSIBILITY OF SUCH DAMAGES. BECAUSE THE APP IS PROVIDED TO YOU FREE OF CHARGE, OUR \
            TOTAL AGGREGATE LIABILITY FOR ALL CLAIMS RELATING TO THE APP WILL NOT EXCEED CAD $20 \
            (TWENTY CANADIAN DOLLARS). Some jurisdictions do not allow certain \
            exclusions or limitations, so some of the above may not apply to you; in that case \
            our liability is limited to the smallest extent permitted by law.
            """),
            Section(heading: "5. Third-Party Services & Data", body: """
            The App connects, at your direction, to third-party services that we neither own nor \
            control — including the Canadian Astronomy Data Centre (CADC) / CANFAR, Anthropic's \
            Claude services, and any container image registries you configure. Your use of those \
            services is governed by their own terms and privacy policies, and you are responsible \
            for your own accounts and credentials with them. We do not warrant the availability, \
            accuracy, completeness, or scientific correctness of any data retrieved from \
            third-party sources, and we are not responsible for their acts, omissions, content, \
            or charges.
            """),
            Section(heading: "6. Third-Party AI Agents & Automation", body: """
            The App does not itself contain or operate any artificial-intelligence model. At your \
            option, you may connect it to — and control it with — third-party AI agents or other \
            MCP clients that you configure (for example, Anthropic's Claude). Those third-party \
            agents, not the App, generate any suggestions, queries, or code, and may, at your \
            direction, take actions through the App such as launching compute sessions, running \
            code, or reading, writing, downloading, or deleting your data. Such outputs and \
            actions can be incomplete or incorrect and are not professional, scientific, or \
            research advice. You are responsible for choosing which agents to connect, for any \
            action you authorize them to take, and for reviewing and confirming results against \
            authoritative sources before relying on them.
            """),
            Section(heading: "7. Acceptable Use", body: """
            You agree to use the App lawfully and in accordance with the terms of any connected \
            service; not to misuse, overload, or attempt to gain unauthorized access to any \
            service; and not to use the App to infringe the rights of others or to store or \
            transmit unlawful content.
            """),
            Section(heading: "8. Changes, Termination & Governing Law", body: """
            We may update the App and these Terms; material changes will be presented for your \
            acceptance. You may stop using the App at any time by deleting it. These Terms are \
            governed by the laws of the Province of British Columbia and the federal laws of Canada \
            applicable therein, without regard to its conflict-of-laws rules, and you agree to \
            the exclusive jurisdiction of the courts of the Province of British Columbia, except where \
            applicable law gives you the right to bring claims elsewhere.
            """),
            Section(heading: "9. Contact", body: """
            Questions about these Terms: support@verbinal.com. If any provision is held \
            unenforceable, the remaining provisions remain in effect.
            """),
        ],
        acceptHeadline: "Welcome to \(appName)",
        acceptSubhead: "Please review and accept the Terms of Use to continue.",
        agreeToggle: "I have read and agree to the Terms of Use, including the disclaimer of warranties and the limitation of liability (including for data loss).",
        agreeButton: "I Agree",
        quitButton: "Quit",
        doneButton: "Done",
        copyButton: "Copy",
        termsLink: "Terms of Use"
    )

    // MARK: - French (Français)

    static let french = Document(
        title: "Conditions d’utilisation et avertissements",
        lastUpdatedLine: "Dernière mise à jour : 2 juin 2026",
        intro: """
        Veuillez lire attentivement les présentes conditions d’utilisation (« Conditions ») avant \
        d’utiliser \(appName) (l’« Application »). En appuyant sur « J’accepte » — ou en installant \
        ou en utilisant l’Application — vous acceptez les présentes Conditions. Si vous n’êtes pas \
        d’accord, n’utilisez pas l’Application.
        """,
        sections: [
            Section(heading: "1. Acceptation et licence", body: """
            \(appName) est fourni par \(developer) (« nous »). Sous réserve des présentes \
            Conditions, nous vous accordons une licence personnelle, non exclusive, non \
            transférable et révocable d’utilisation de l’Application sur les appareils que vous \
            possédez ou contrôlez, pour votre usage personnel non commercial ou de recherche \
            interne. Lorsque l’Application est obtenue via l’App Store d’Apple, le Contrat de \
            licence d’utilisateur final des applications sous licence d’Apple s’applique \
            également et, en cas de conflit avec les présentes Conditions, les conditions \
            minimales d’Apple régissent cette distribution.
            """),
            Section(heading: "2. Absence de garantie — fournie « EN L’ÉTAT »", body: """
            L’APPLICATION EST FOURNIE « EN L’ÉTAT » ET « SELON DISPONIBILITÉ », SANS GARANTIE \
            D’AUCUNE SORTE, QU’ELLE SOIT EXPRESSE, IMPLICITE OU LÉGALE. DANS TOUTE LA MESURE \
            PERMISE PAR LA LOI, NOUS DÉCLINONS TOUTE GARANTIE, Y COMPRIS LES GARANTIES IMPLICITES \
            DE QUALITÉ MARCHANDE, D’ADÉQUATION À UN USAGE PARTICULIER, DE TITRE, DE \
            NON-CONTREFAÇON, AINSI QUE TOUTE GARANTIE QUE L’APPLICATION SERA ININTERROMPUE, \
            EXEMPTE D’ERREURS, SÉCURISÉE, OU QUE LES DONNÉES SERONT EXACTES, CONSERVÉES OU \
            RÉCUPÉRABLES. Vous utilisez l’Application à vos propres risques.
            """),
            Section(heading: "3. Vos données et sauvegardes", body: """
            L’Application stocke votre contenu — notamment les notes de recherche, les \
            évaluations, les étiquettes, les requêtes enregistrées, les fichiers téléchargés et \
            les préférences — localement sur votre appareil. Nous n’exploitons aucun service de \
            sauvegarde ou de synchronisation pour ce contenu. Un logiciel peut comporter des \
            défauts susceptibles d’altérer, d’écraser ou de supprimer des données, et des \
            défaillances du système d’exploitation, du matériel ou du stockage peuvent faire de \
            même. VOUS ÊTES SEUL RESPONSABLE DE LA CONSERVATION DE SAUVEGARDES INDÉPENDANTES de \
            toute donnée à laquelle vous tenez. Utilisez régulièrement la fonction d’exportation \
            de l’Application ainsi que votre propre système de sauvegarde. Nous ne sommes pas \
            responsables de toute perte, altération ou inaccessibilité de vos données.
            """),
            Section(heading: "4. Limitation de responsabilité", body: """
            DANS TOUTE LA MESURE PERMISE PAR LA LOI, NOUS NE SAURIONS EN AUCUN CAS ÊTRE TENUS \
            RESPONSABLES DE DOMMAGES INDIRECTS, ACCESSOIRES, SPÉCIAUX, CONSÉCUTIFS, EXEMPLAIRES OU \
            PUNITIFS, NI D’UNE PERTE DE DONNÉES, D’UNE PERTE DE TRAVAUX DE RECHERCHE, D’UN MANQUE \
            À GAGNER OU D’UNE ATTEINTE À LA RÉPUTATION, DÉCOULANT DE VOTRE UTILISATION (OU DE \
            VOTRE INCAPACITÉ À UTILISER) L’APPLICATION, MÊME SI NOUS AVIONS ÉTÉ INFORMÉS DE LA \
            POSSIBILITÉ DE TELS DOMMAGES. L’APPLICATION VOUS ÉTANT FOURNIE GRATUITEMENT, NOTRE \
            RESPONSABILITÉ GLOBALE TOTALE POUR TOUTE RÉCLAMATION RELATIVE À L’APPLICATION \
            N’EXCÉDERA PAS 20 $ CA (VINGT DOLLARS CANADIENS). Certaines juridictions n’autorisent pas \
            certaines exclusions ou limitations ; il se peut donc que ce qui précède ne \
            s’applique pas à vous ; dans ce cas, notre responsabilité est limitée dans la mesure \
            la plus restreinte permise par la loi.
            """),
            Section(heading: "5. Services et données de tiers", body: """
            L’Application se connecte, à votre demande, à des services tiers que nous ne possédons \
            ni ne contrôlons — notamment le Centre canadien de données astronomiques (CADC) / \
            CANFAR, les services Claude d’Anthropic, et tout registre d’images de conteneurs que \
            vous configurez. Votre utilisation de ces services est régie par leurs propres \
            conditions et politiques de confidentialité, et vous êtes responsable de vos propres \
            comptes et identifiants auprès d’eux. Nous ne garantissons pas la disponibilité, \
            l’exactitude, l’exhaustivité ou l’exactitude scientifique des données obtenues de \
            sources tierces, et nous ne sommes pas responsables de leurs actes, omissions, \
            contenus ou frais.
            """),
            Section(heading: "6. Agents d’IA tiers et automatisation", body: """
            L’Application ne contient ni n’exécute elle-même aucun modèle d’intelligence \
            artificielle. À votre choix, vous pouvez la connecter à des agents d’IA tiers ou à \
            d’autres clients MCP que vous configurez (par exemple, Claude d’Anthropic) et la \
            commander au moyen de ceux-ci. Ce sont ces agents tiers, et non l’Application, qui \
            génèrent les suggestions, les requêtes ou le code, et qui peuvent, à votre demande, \
            effectuer des actions via l’Application telles que lancer des sessions de calcul, \
            exécuter du code, ou lire, écrire, télécharger ou supprimer vos données. Ces \
            résultats et actions peuvent être incomplets ou incorrects et ne constituent pas des \
            conseils professionnels, scientifiques ou de recherche. Il vous incombe de choisir \
            les agents à connecter, d’assumer toute action que vous les autorisez à effectuer, et \
            de vérifier et confirmer les résultats auprès de sources faisant autorité avant de \
            vous y fier.
            """),
            Section(heading: "7. Utilisation acceptable", body: """
            Vous acceptez d’utiliser l’Application de manière licite et conformément aux \
            conditions de tout service connecté ; de ne pas détourner, surcharger ou tenter \
            d’accéder sans autorisation à un service ; et de ne pas utiliser l’Application pour \
            porter atteinte aux droits d’autrui ni pour stocker ou transmettre des contenus \
            illicites.
            """),
            Section(heading: "8. Modifications, résiliation et droit applicable", body: """
            Nous pouvons mettre à jour l’Application et les présentes Conditions ; les \
            modifications importantes seront soumises à votre acceptation. Vous pouvez cesser \
            d’utiliser l’Application à tout moment en la supprimant. Les présentes Conditions sont \
            régies par les lois de la province de la Colombie-Britannique et les lois fédérales du Canada qui \
            y sont applicables, sans égard à ses règles de conflit de lois, et vous acceptez la \
            compétence exclusive des tribunaux de la province de la Colombie-Britannique, sauf lorsque la loi \
            applicable vous donne le droit d’intenter des actions ailleurs.
            """),
            Section(heading: "9. Contact", body: """
            Questions concernant les présentes Conditions : support@verbinal.com. Si une \
            disposition est jugée inapplicable, les autres dispositions demeurent en vigueur.
            """),
        ],
        acceptHeadline: "Bienvenue dans \(appName)",
        acceptSubhead: "Veuillez lire et accepter les conditions d’utilisation pour continuer.",
        agreeToggle: "J’ai lu et j’accepte les conditions d’utilisation, y compris l’exclusion de garanties et la limitation de responsabilité (notamment en cas de perte de données).",
        agreeButton: "J’accepte",
        quitButton: "Quitter",
        doneButton: "Terminé",
        copyButton: "Copier",
        termsLink: "Conditions d’utilisation"
    )
}
