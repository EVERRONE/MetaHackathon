# Visuele AI-taakbegeleider — productdefinitie v0.1

Datum: 30 oktober 2026. Status: concreet voorstel voor de eerste bouwversie; geen bewijs van technische werking of marktvalidatie. Dit document verwerkt de gewenste persoonlijke metgezel, visuele aanwijzingen, toepassingen thuis en op het werk, de iPhone als testapparaat en de ambitie om later Meta-brillen te ondersteunen.

## 1. Wat we bouwen

Een interactieve camera-app die een gebruiker door een fysieke taak begeleidt. De gebruiker toont de situatie en stelt vragen. De app combineert het camerabeeld met een gecontroleerde instructie, wijst relevante voorwerpen aan, geeft één volgende handeling en bewaart de bevestigde voortgang.

Productbelofte: **Ik kijk met je mee, toon waar je moet handelen en begeleid je stap voor stap.**

De eerste versie is een mobiele webapp voor Safari op iPhone. Een eigen server verwerkt verzoeken aan AI-modellen. Installatie uit de App Store is voor het prototype geen vereiste. Camera en microfoon worden pas na toestemming gebruikt, via een beveiligde verbinding. De daadwerkelijke browserwerking wordt vroeg op de gebruikte iPhone getest.

De langetermijnvorm is een metgezel via een bril: handsfree kijken, spreken en visuele begeleiding ontvangen. Het telefoonprototype test de begeleiding; het bewijst nog geen handsfree gebruik, nauwkeurige ruimtelijke projectie of volledige brilintegratie.

## 2. Voor wie en voor welk probleem

Eerste gebruiker: iemand die een onbekende praktische taak probeert uit te voeren en de instructie moeilijk op de eigen situatie kan toepassen.

Typische vragen: welk onderdeel bedoelt de handleiding, hoe moet ik het houden, welke stap volgt, en waar was ik gebleven?

Professionele vervolggebruiker: een medewerker die een minder vertrouwde procedure uitvoert met bedrijfsinstructies als bron. Dezelfde sessieopbouw kan hiervoor bruikbaar zijn; bedrijfsspecifieke toegang, goedkeuring en beheer vallen buiten deze eerste versie.

De eerste te toetsen waarde is zelfstandig een taak voltooien met minder vastlopers en hulpvragen. Bereidheid om te betalen en de keuze tussen consumenten en bedrijven zijn nog onbewezen. Er komt in v1 geen abonnement, betaling of zakelijke verkoopomgeving.

## 3. Eén complete eerste taak

Voorgestelde demotaak: een klein montageproject met ongeveer vijf tot tien stappen en visueel onderscheidbare onderdelen. Het exacte beschikbare meubel of bouwpakket moet nog worden gekozen. Een merknaam zoals IKEA is een voorbeeld, geen beloofde integratie of algemene dekking.

Voor die taak maken we vooraf één gecontroleerd taakpakket: productidentiteit, broninstructie, stappen, onderdeelbenamingen, referentiebeelden, verwachte handelingen en controlepunten. Het pakket wordt tijdens ontwikkeling samengesteld. De gebruiker hoeft geen AI-prompts of stappenplan te schrijven.

De app moet op nieuwe cameraopnamen kunnen reageren, bijvoorbeeld wanneer onderdelen anders liggen of een hand gedeeltelijk in beeld komt. Vooraf gemaakte demoantwoorden of vaste pijlen zijn geen bewijs van werking. De handleiding mag bekend zijn; de camerabeelden en vragen worden daadwerkelijk verwerkt.

Het takenformaat wordt herbruikbaar. Een tweede toestel of procedure kan later als nieuw pakket worden toegevoegd. Koken, algemene LEGO-ondersteuning, vaatwassers en voertuigtaken worden hiermee nog niet automatisch ondersteund. Een willekeurige handleiding volledig automatisch omzetten naar betrouwbare begeleiding is eveneens een latere ontwikkeling.

## 4. De volledige gebruikerservaring

1. **Starten.** De gebruiker opent de app en kiest de ondersteunde taak. De app toont welk product en welke bron worden gebruikt.
2. **Kijken.** De gebruiker geeft cameratoegang. Het livebeeld vult het grootste deel van het scherm. Camera wisselen en tekstinvoer zijn beschikbaar.
3. **Een vraag stellen.** De gebruiker tikt op de spreekknop en vraagt bijvoorbeeld: “Waar begin ik?” Tijdens deze actieve opname luistert de app. Een getypte vraag werkt ook.
4. **Een beeld vastleggen.** De app gebruikt één geselecteerd beeld voor de analyse. De gebruiker ziet welk beeld wordt onderzocht. Een opname kan opnieuw worden gemaakt.
5. **Aanwijzen en uitleggen.** De app toont op dat beeld een markering met één korte instructie. Het antwoord kan worden voorgelezen. De actieve stap en de gebruikte bron zijn opvraagbaar.
6. **Doorvragen.** “Bedoel je deze?”, “Waarom?” of “Leg het eenvoudiger uit” verandert de bevestigde stap niet. Een nieuwe visuele vraag gebruikt een nieuw beeld.
7. **Uitvoeren en controleren.** De gebruiker voert de handeling uit. De app vraagt de vooraf bepaalde controle of een bevestiging. Alleen wat zichtbaar te controleren is, kan als visuele waarneming worden beschreven.
8. **Verdergaan.** De gebruiker bevestigt de stap met stem of knop. De software registreert expliciet of dit een gebruikersbevestiging is. Dat is geen automatische technische keuring.
9. **Pauzeren en hervatten.** De laatste bevestigde stap blijft op dit toestel bewaard. Na hervatten wordt de actuele fysieke situatie opnieuw getoond voordat nieuwe plaatsgebonden aanwijzingen worden gegeven.

Een knop “vorige stap” blijft beschikbaar. Bij het opnieuw openen van een eerder voltooide stap vraagt de app welke handelingen nog werkelijk uitgevoerd zijn; hij veronderstelt niet dat de fysieke taak automatisch is teruggedraaid.

## 5. Wat er op het scherm verschijnt

Er zijn drie eenvoudige schermen: taak kiezen, actieve begeleiding en afronding.

Tijdens begeleiding zijn zichtbaar: het camerabeeld of geanalyseerde beeld, een kleine metgezel, één instructiekaart, de voortgang, een spreekknop, een knop voor een nieuw beeld en pauzeren. Meer uitleg en de bron zijn beschikbaar zonder het beeld standaard met tekst te vullen.

De metgezel heeft herkenbare toestanden: klaar, luisteren, kijken/verwerken, uitleggen en verduidelijking nodig. Hij onderbreekt de gebruiker niet voortdurend en krijgt in v1 geen uitgebreide avatarpersonalisatie.

Drie soorten visuele aanwijzingen:

- **Objectmarkering:** omlijning of kader rond het relevante onderdeel, met een kort label.
- **Aanwijspijl:** wijst naar de zichtbare plek waarop de uitleg betrekking heeft.
- **Handelingsschema:** een duidelijk als illustratie herkenbare richtingspijl of referentieafbeelding voor een beweging of oriëntatie.

Een schema mag niet de indruk wekken dat een onzichtbare aansluiting exact is gelokaliseerd. Voor fysieke instructies gebruiken we gecontroleerde bronbeelden en getekende aanwijzingen; fotorealistisch gegenereerde montagebeelden behoren niet tot de eerste versie.

## 6. Gedrag van de visuele begeleiding

In v1 zijn markeringen gekoppeld aan het specifieke vastgelegde beeld. Het scherm vermeldt dat dit een momentopname is. Bij terugkeer naar livebeeld verdwijnen de markeringen. Een oud kader blijft dus nooit over nieuwe camerabeelden staan alsof het nog klopt.

Bij een ander beeld, veranderde onderdelen of hervatting moet opnieuw worden gekeken. De app houdt rekening met uitsnede, beeldverhouding en schermrotatie bij het tekenen van markeringen. Als het doelobject niet eenduidig gevonden wordt, verschijnt geen stellige aanwijzing. De assistent vraagt een andere kijkhoek, benoemt meerdere kandidaten of vraagt de gebruiker een kandidaat aan te tikken.

Live 2D-tracking in het camerabeeld is een volgende uitbreiding. Nauwkeurige, ruimtelijk verankerde aanwijzingen door een bril zijn een afzonderlijk onderzoek. De beschikbaarheid van een brillendisplay of een videosimulator bewijst die mogelijkheid niet.

## 7. Wat de assistent weet en onthoudt

Per sessie houdt de app bij: taak en bronversie, huidige stap, bevestigde stappen, openstaande vraag en een korte relevante gesprekssamenvatting. Het laatste beeld is alleen context voor de huidige visuele beoordeling.

De toepassing onderscheidt drie zaken: informatie uit de instructie, waarnemingen op een beeld en verklaringen van de gebruiker. Een uitspraak als “klaar” wordt niet stilzwijgend omgezet in “visueel correct bevonden”.

De assistent geeft geen garantie over een onzichtbare bevestiging, kracht, temperatuur of andere niet waarneembare eigenschap. Voor productgebonden instellingen vraagt hij de toepasselijke bron. In de eerste versie blijft hij bij het ondersteunde taakpakket. Een onbekend model leidt tot een uitleg over de ontbrekende ondersteuning.

## 8. Technische onderdelen

| Onderdeel | Verantwoordelijkheid |
|---|---|
| iPhone-webapp | Camera, korte audio-opname, tekstinvoer, aanwijzingen tekenen, antwoorden tonen en voorlezen. |
| Sessielogica | Huidige stap, bevestigingen, teruggaan, pauzeren en hervatten. De software bewaakt deze overgangen. |
| Taakpakket | Gecontroleerde stappen, bronverwijzingen, onderdelen, voorbeeldbeelden en controlepunten. |
| AI-verwerking | Vraag en beeld in relatie tot de huidige taak interpreteren en een gestructureerd antwoord voorstellen. |
| Visuele lokalisatie | Kandidaten voor het bedoelde object vinden en de bruikbare beeldcoördinaten teruggeven. |
| Server | Modeltoegang, verzoeklimieten, validatie, foutafhandeling en bescherming van API-sleutels. |

Voorgestelde modelverdeling: Muse Spark verwerkt vragen, beelden en taakcontext; SAM 3.1 levert objectkaders of maskers; Muse Voice Transcribe zet opgenomen spraak om in tekst. SAM bepaalt daarmee niet of een montage correct is. Voor het uitspreken van antwoorden wordt eerst de spraakweergave van de browser getest, met tekst als blijvende terugval. Muse Voice Transcribe levert zelf geen gesproken antwoorden. Modeltoegang, snelheid, taalgedrag en de kwaliteit op onze onderdelen moeten in een technische proef worden bevestigd. [Meta-modeldocumentatie](https://dev.meta.ai/docs/models), [SAM-documentatie](https://dev.meta.ai/docs/sam/overview), [browser-spraakweergave](https://developer.mozilla.org/en-US/docs/Web/API/SpeechSynthesis).

De AI retourneert bijvoorbeeld antwoordtekst, een doelobject, gevraagde verduidelijking, een bronverwijzing en een voorgesteld controlepunt. De server valideert dat deze informatie bij het taakpakket en het gebruikte beeld hoort. Antwoorden starten niet zelfstandig onbeperkte taken en veranderen niet rechtstreeks de opgeslagen stap.

## 9. Gegevens en bediening

Het live camerabeeld blijft lokaal totdat de gebruiker een beeld laat analyseren. Alleen benodigde geselecteerde beelden, actieve audio-opnamen, vragen en relevante taakcontext gaan naar de server en de gebruikte modelprovider. De eerste versie neemt niet voortdurend de omgeving op.

Voortgang en beperkte tekstcontext worden op het toestel opgeslagen en kunnen worden gewist. Ruwe beelden en audio krijgen geen permanente opslag in onze eigen applicatie; tijdelijke verwerking is noodzakelijk. De afzonderlijke verwerking en bewaartermijnen van modelproviders moeten vóór gebruik met echte gebruikers worden gecontroleerd. We beloven dus niet dat gegevens de telefoon nooit verlaten.

Camera- en microfoontoestemming zijn afzonderlijk herkenbaar. Zonder microfoon werkt tekstinvoer. Bij een model- of netwerkfout blijft de goedgekeurde instructie leesbaar en kan de gebruiker opnieuw proberen. API-sleutels staan uitsluitend op de server.

Voor cameratoegang gebruiken we HTTPS en expliciete browsertoestemming. De eerste technische proef controleert camera, audio-opname, audio-uitvoer en schermgedrag in Safari op de daadwerkelijke iPhone. [Browserdocumentatie voor cameratoegang](https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getUserMedia).

## 10. Route naar Meta-brillen

Camera-invoer, taaklogica en weergave krijgen gescheiden verantwoordelijkheden, zodat een toekomstige mobiele integratie dezelfde taaklogica kan gebruiken. Dat beperkt herbouw, maar maakt een webapp niet automatisch compatibel met de bril.

Meta documenteert een Device Access Toolkit voor mobiele toepassingen en een aparte route voor webapps op Display-brillen. De Mock Device Kit en de Display-webappsimulator hebben verschillende doelen en vervangen geen volledig onderzoek op hardware. [Meta Wearables FAQ](https://developers.meta.com/wearables/faq/).

Voor echte brilondersteuning moeten we later ten minste camera- en audio-invoer, toegestane displayweergave, bediening, vertraging en beschikbaarheid op het gekozen toestel testen. Voor markeringen die bij echte voorwerpen blijven staan is aanvullend bewijs nodig over ruimtelijke tracking en uitlijning. Het telefoonprototype en een eventuele simulatorweergave worden expliciet als zodanig gepresenteerd.

## 11. Wanneer v1 geslaagd is

Functionele acceptatie:

- De gebruiker kan op de gekozen iPhone een volledige ondersteunde taak starten en afronden.
- Vragen en echte cameraopnamen worden door de modellen verwerkt; er zijn geen verborgen vaste antwoorden die modelwerking vervangen.
- De app markeert doelobjecten op nieuwe, niet vooraf gebruikte beelden van de taak.
- Bij meerdere plausibele onderdelen of onvoldoende zicht vraagt hij verduidelijking.
- Een vraag verandert de stap niet; alleen een expliciete voortgangsactie doet dat.
- Oude markeringen verdwijnen zodra een nieuw livebeeld wordt getoond.
- Pauzeren en heropenen herstellen de bevestigde voortgang en vragen een nieuwe situatiecontrole.
- Bij geweigerde microfoontoegang of een netwerkfout blijft een begrijpelijke route beschikbaar.

Voorlopige testdoelen, geen huidige prestaties: op tien ongebruikte testbeelden minstens acht bruikbare correcte aanwijzingen en geen stellige aanwijzing naar een verkeerd object; in overige gevallen verduidelijking. Voor reacties streven we naar een mediane wachttijd van maximaal acht seconden op het testnetwerk en rapporteren we ook trage uitschieters. Deze kleine proef bewijst geen algemene betrouwbaarheid.

Daarna laten we drie tot vijf nieuwe gebruikers een taak proberen. We registreren voltooiing, vastlopers, hulpvragen, correcties, wachttijd en hinder door de interface. Voor een vergelijking met een handleiding gebruiken we vergelijkbare taken en wisselen we de volgorde om leereffecten te beperken. De resultaten blijven verkennend.

## 12. Bouwvolgorde en oplevering

1. Kies het concrete taakobject en stel het gecontroleerde taakpakket samen.
2. Test op de iPhone de volledige technische keten: beeld + vraag naar model, antwoord terug, gesproken weergave en correcte plaatsing van één markering.
3. Bouw de begeleidingssessie met gecontroleerde stapovergangen, doorvragen en hervatten.
4. Voeg objectlokalisatie, verduidelijkingsgedrag en beeldgebonden markeringen toe; toets nieuwe beelden.
5. Werk de metgezel en korte instructies af, test met gebruikers en leg echte resultaten vast.
6. Maak desgewenst een afzonderlijke simulatorweergave voor de brilambitie, nadat de telefoonervaring werkt.

De oplevering bestaat uit de iPhone-webapp, bijbehorende servercode, één compleet taakpakket, een korte gebruiksinstructie en een testverslag met bekende beperkingen. Publicatie of indiening bij de hackathon volgt als afzonderlijke keuze; dit document geeft daar geen opdracht voor.

Nog open voor de concrete bouwstart: het exacte beschikbare montageobject met instructie, de iPhone/Safari-versie en daadwerkelijke toegang tot de benodigde Meta-modellen. De eerste scope bevat één gebruiker, één toestel, één taakpakket en Nederlands als testtaal.

## 13. Wat we later beslissen

De mogelijke startup richt zich op consumentenondersteuning, professionele taakbegeleiding of productondersteuning namens een fabrikant. De eerste demo beslist dat nog niet. We kiezen die richting op basis van herhaald gebruik, aantoonbare waarde, kosten per sessie en gesprekken met mogelijke klanten.

Voor een volgende versie onderzoeken we live aanwijzingen, extra taakpakketten en echte brilbediening. Automatische verwerking van willekeurige handleidingen, continue observatie, brede persoonlijke herinneringen, meertaligheid, teambeheer en een marktplaats voor instructies krijgen pas prioriteit als de kernervaring waarde blijkt te hebben.
