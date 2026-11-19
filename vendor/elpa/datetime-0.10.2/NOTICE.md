# Provenienza e licenze dei dati di datetime

Il codice di datetime 0.10.2 è distribuito sotto [GPL-3.0 o successiva](LICENSE).
Le tre tabelle incluse corrispondono a quelle della revisione
[b8e5fc2](https://github.com/doublep/datetime/tree/b8e5fc2b7338f26ee816a3b03322c585dbd3b686).
Il progetto originale le genera con [HarvestData.java](dev/HarvestData.java)
e le regole di compilazione in [Eldev](Eldev).

- `locale-data.extmap` e `timezone-name-data.extmap` incorporano dati di
  localizzazione estratti da OpenJDK 17.0.8+7-1 (Debian). Si applica anche
  l'[avviso Unicode CLDR 39](../../licenze/OpenJDK-17-CLDR.md) incluso in OpenJDK.
  [Rigenerazione a monte](https://github.com/doublep/datetime/commit/4d11de332682e9942ad00c0ac86d79c8e1789329)
- `timezone-data.extmap` contiene regole dei fusi orari estratte da OpenJDK
  17.0.14+7-Debian-1deb12u1. I dati di base mantengono l'[avviso IANA TZDB](../../licenze/IANA-TZDB.txt).
  Per il materiale proveniente da OpenJDK, sono inclusi anche l'[avviso
  delle fonti TZDB di OpenJDK](../../licenze/OpenJDK-17-TZDATA.txt) e il
  [testo GPL v2 con eccezione Classpath](../../licenze/OpenJDK-17-LICENSE.txt).
  [Rigenerazione a monte](https://github.com/doublep/datetime/commit/2e6f050e02541f1ce9ff8ea1319276b8b9232324)
