#!/bin/bash

### requisiti ###
# curl
# jq
# csvkit (si installa via pip di python)
# pyexcel-cli (si installa via pip di python)
# pyexcel-ods3 (si installa via pip di python)
# perl (di solito preinstallato)
# cs2cs
# pup
# Mapshaper
### requisiti ###

set -x

cartella=$(pwd)

# creo due cartelle "contenitore"
mkdir -p "$cartella"/ods
mkdir -p "$cartella"/csv

# svuoto la cartella dove inserirò i file di download
rm "$cartella"/ods/*.ods

# scarico URL e nome dei luoghi, dei soli alberi il cui iter amministrativo di iscrizione è completo http://bit.ly/2E9tRP6
curl -L "https://www.politicheagricole.it/flex/cm/pages/ServeBLOB.php/L/IT/IDPagina/11260" | sed -r "s|&#039.||g" | pup "div.BLOBWidth50 > div > div > a:nth-child(1) json{}" | sed -r 's/ - aggiornato al.*?B.//g' | jq '[.[] | {href:.href,name:.title|gsub(" ";"")}]' | in2csv -I -f json >"$cartella"/file.csv

# rimuovo la prima riga
sed -i '1d' "$cartella"/file.csv

# scarico i file elencati nell'anagrafica, ovvero quelli del file file.csv
INPUT="$cartella"/file.csv
OLDIFS=$IFS
IFS=,
[ ! -f $INPUT ] && {
	echo "$INPUT file not found"
	exit 99
}
while read href name; do
	curl -sL "$href" >"$cartella"/ods/"$name".ods
done <$INPUT
IFS=$OLDIFS

# cancello il file con l'anagrafica dei file da scaricare
rm "$cartella"/file.csv

# rimuovo vecchi file CSV
rm "$cartella"/csv/*.csv

# converto tutti i file .ods in csv
for i in "$cartella"/ods/*.ods; do
	#creo una variabile che uso per estrarre nome e estensione
	filename=$(basename "$i")
	#estraggo estensione
	extension="${filename##*.}"
	#estraggo nome file
	filename="${filename%.*}"
	pyexcel transcode --sheet-index 0 "$i" "$cartella"/csv/"$filename".csv
done

# pulisco e ristrutturo i csv di output
for i in "$cartella"/csv/*.csv; do
	filename=$(basename "$i")
	extension="${filename##*.}"
	filename="${filename%.*}"
	# rimuovo i caretteri "\n" dalle celle, è il ritorno a capo interno a queste
	perl <"$i" -pe 's/\r\n/~~/' | perl -pe 's/\n/ /' | sed 's/~~/\n/g' >"$cartella"/csv/"$filename"_tmp.csv
	cat "$cartella"/csv/"$filename"_tmp.csv >"$i"
	# rimuovo dai CSV tutte le righe inutili (triple intestazioni, footer, ecc..), che sono quelle che non iniziano per numero
	sed -i -n '/^[0-9].*$/p' "$i"
	# aggiungo riga intestazione
	sed '1s|^|ID,N. SCHEDA,PROVINCIA,COMUNE,LOCALITÀ,LATITUDINE su GIS,LONGITUDINE su GIS,ALTITUDINE (m s.l.m.),CONTESTO URBANO sì/no,NOME SCIENTIFICO,NOME VOLGARE,CIRCONFERENZA FUSTO (cm),ALTEZZA (m),CRITERI DI MONUMENTALITÀ,PROPOSTA DICHIARAZIONE NOTEVOLE INTERESSE PUBBLICO\n|' "$i" >"$cartella"/csv/"$filename"_tmp.csv
	# rimuovo le colonne nascoste che erano presenti nei file ods, ovvero dalla 16 in poi, quindi tengo soltanto da 1 a 15
	csvcut -c 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15 "$cartella"/csv/"$filename"_tmp.csv >"$cartella"/csv/"$filename"_tmp2.csv
	# aggiungo una colonna con il nome del file
	csvsql -I --query 'select *,"'"$filename"'.csv" AS nomefile from '"$filename"'_tmp2' "$cartella"/csv/"$filename"_tmp2.csv >"$i"
	rm "$cartella"/csv/"$filename"_tmp*.csv
	# rimuovo eventuali doppi spazi
	sed -i -r 's/ +/ /g' "$i"
done

# estraggo le coordinate in formato numerico (da 14°21'48,11'' a 14.363611) in due colonne
# e aggiungo queste colonne ai CSV creati
for i in "$cartella"/csv/*.csv; do
	filename=$(basename "$i")
	extension="${filename##*.}"
	filename="${filename%.*}"
	# estraggo soltanto le colonne con latitude e longitude e poi sostituisco il decimale da "," a ".",
	# converto il carattere "°" in "d", e estraggo via regex i dati geografici in una modalità leggibile da cs2cs
	csvsql -I --query 'select "LONGITUDINE su GIS" as longitude, "LATITUDINE su GIS" as latitude from '"$filename"'' "$i" | tee "$cartella"/csv/"$filename"_tmp_raw1.txt | sed 's/°/d/g;s/,/./g;s/ //g;s/^/"/g;s/$/"/g' | perl -pe 's/^[^0-9]{1,5}([0-9]{1,3})(d ?)([0-9]{1,2})([^0-9]{1,5})([0-9]{1,2}\.?[0-9]{0,2})([^0-9]+)([0-9]{1,3})(d ?)([0-9]{1,2})([^0-9]{1,5})([0-9]{1,2}\.?[0-9]{0,2})(.*)$/$1d$3k$5\" $7d$9k$11\"/' | tee "$cartella"/csv/"$filename"_tmp_raw2.txt | sed "s/k/'/g" | sed '1d' >"$cartella"/csv/"$filename"_tmp.txt
	# converto le coordinate in gradi decimali
	cs2cs -f "%.6f" +proj=latlong +datum=WGS84 "$cartella"/csv/"$filename"_tmp.txt >"$cartella"/csv/"$filename".txt
	# inserisco una intestazione
	sed -i '1s|^|longitude\tlatitude\n|' "$cartella"/csv/"$filename".txt
	# rimuovo una stringa inutile
	sed -i 's/ 0.000000//g;s/\t/,/g' "$cartella"/csv/"$filename".txt
	cp "$i" "$cartella"/csv/"$filename"_tmp.csv
	# ai file csv aggiungo le due colonne con la coordinate, concatenando in orizzontale i file csv originali
	# e i file txt creati
	csvjoin -I "$cartella"/csv/"$filename"_tmp.csv "$cartella"/csv/"$filename".txt >"$i"
	# cancello i vari file temporanei creati
	rm "$cartella"/csv/"$filename"_tmp*.csv
	rm "$cartella"/csv/*.txt
done

# unisco tutti i vari file dei vari territori in un unico file
csvstack "$cartella"/csv/*.csv >"$cartella"/csv/alberiMonumentali.csv

# rimuovo dal dataset i record che non hanno errori nelle colonne con le coordinate (quelle che contegono 000000 e quella che ha lat e lon invertite, in cui lon inizia per "3") e/o con coordinate mancanti
grep -v "000000" "$cartella"/csv/alberiMonumentali.csv | csvgrep -c "longitude" -i -r "^3" >"$cartella"/alberiMonumentali.csv

# estraggo i record che hanno problemi con le coordinate e/o con coordinate mancanti
<"$cartella"/csv/alberiMonumentali.csv | csvgrep -c "latitude" -r "[^0-9]$" | csvcut -C "longitude,latitude" >"$cartella"/alberiMonumentaliErroriCoordinate.csv

# Inserisco un '|' nella colonna "CRITERI DI MONUMENTALITÀ"
# da "a) età e/o dimensioni b) forma e portamento" a "a) età e/o dimensioni|b) forma e portamento"
cat "$cartella"/alberiMonumentali.csv | csvcut -c "14" | sed -r 's/(\s)([a-z])(\))/|\2\3/g;s/( )+$//g;s/ "$/"/g' >"$cartella"/csv/criteri.csv
csvcut <"$cartella"/alberiMonumentali.csv -C "14" >"$cartella"/csv/alberiMonumentali_tmp.csv
paste "$cartella"/csv/alberiMonumentali_tmp.csv "$cartella"/csv/criteri.csv | sed 's/\t/,/' >"$cartella"/alberiMonumentali.csv

# creo il geojson
csvjson -I --lat "latitude" --lon "longitude" "$cartella"/alberiMonumentali.csv >"$cartella"/alberiMonumentali.geojson

# estraggo i codici comunali ISTAT corrispondenti alle coordinate degli alberi
mapshaper "$cartella"/alberiMonumentali.geojson -join "$cartella"/risorse/comuni.shp fields=PRO_COM_T -o "$cartella"/csv/alberiMonumentaliISTAT.csv
cat "$cartella"/alberiMonumentali.csv > "$cartella"/csv/alberiMonumentali.csv
csvsql -I --query "select a.*,b.PRO_COM_T from alberiMonumentali as a left join alberiMonumentaliISTAT as b on a.id=b.id AND a.comune=b.comune" "$cartella"/csv/alberiMonumentali.csv "$cartella"/csv/alberiMonumentaliISTAT.csv > "$cartella"/alberiMonumentali.csv

# converto in GeoJSON i dati in CSV con le informazioni ISTAT
csvjson -i 4 -I --lat "latitude" --lon "longitude" "$cartella"/alberiMonumentali.csv >"$cartella"/alberiMonumentali.geojson
