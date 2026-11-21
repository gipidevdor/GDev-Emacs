# Voce GDev (originale Earwig)

Fork di Earwig 0.2.0, revisione ecfb12505ec72ffb8e45d25390092c0988c3e583.
Licenza GPL-3.0-or-later; avvisi e licenza originali conservati.

Adattamento del 21 novembre 2026: punti d’integrazione opzionali per grammatica,
processamento del testo, controllo del contesto delle risposte e indicatore di
stato del chiamante. I valori nil mantengono il comportamento originale.
GDev fornisce grammatica italiana, azioni del proprio catalogo, motore locale,
lettura e ciclo di vita dei documenti; le scorciatoie originali non vengono
attivate automaticamente. Le prove originali sono conservate in test/.

Correzioni del fork, 21 novembre 2026: sostituzione delle virgolette Unicode
compatibile con Emacs 30 e 31, conservando proprietà e tabella sintattica;
annullamento completo delle registrazioni, richieste e file temporanei di
proprietà del pacchetto. Le sentinelle vengono scollegate prima dell'arresto
per impedire che una risposta tardiva interferisca con una nuova registrazione.
Le richieste HTTP hanno un limite configurabile e usano opzioni curl
disponibili anche nelle versioni di sistema precedenti. L'adattatore può
indicare che una trascrizione è già stata ripulita, evitando di applicare
due volte le correzioni personali.
