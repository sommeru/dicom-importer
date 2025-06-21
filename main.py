import os
import shutil
import customtkinter as ctk
import tkinter as tk
from tkinter import filedialog, messagebox
import pydicom
import subprocess
import shutil

# Config setzen
destination_path = "/Users/sommeru/Downloads/tmp"

# Globale Valiablen
dicom_folder = None
current_patient_info = None

# Grundstil definieren
app = ctk.CTk()
app.title("DICOM-Importer")
icon_image = tk.PhotoImage(file="icon.png")
app.iconphoto(True, icon_image)

ctk.set_appearance_mode("System")  # "Dark", "Light", "System"
ctk.set_default_color_theme("blue")  # Andere Optionen: "green", "dark-blue"

def get_disk_usage_percent(path):
    """Gibt (genutzt, frei, total, prozent_benutzt) zurück"""
    try:
        total, used, free = shutil.disk_usage(path)
        percent_used = int(used / total * 100)
        return used, free, total, percent_used
    except Exception as e:
        print(f"Fehler bei der Speicherabfrage: {e}")
        return 0, 0, 0, 0

def update_disk_usage_display():
    used, free, total, percent = get_disk_usage_percent(destination_path)
    disk_progress.set(percent / 100)
    total_gb = total / (1024**3)
    free_gb = free / (1024**3)
    disk_info_label.configure(
        text=f"Frei: {free_gb:.1f} GB von {total_gb:.1f} GB ({100 - percent} % frei)"
    )

def get_folder_size(path):
    try:
        result = subprocess.run(
            ["du", "-sk", path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True
        )
        size_kb = int(result.stdout.split()[0])
        size_mb = size_kb // 1024  # Abrunden auf volle MB
        return size_mb
    except Exception as e:
        print(f"Fehler beim Ermitteln der Ordnergröße: {e}")
        return 0.0

def extract_patient_info_from_folder(folder_path):
    patient_info = []
    readoutcomplete = False
    for root, _, files in os.walk(folder_path):
        for file in files:            
            file_path = os.path.join(root, file)
            try:
                ds = pydicom.dcmread(file_path, stop_before_pixels=True)

                name = ds.get("PatientName", "Doe_John")
                birth_date = ds.get("PatientBirthDate", "19000101")
                study_date = ds.get("StudyDate", "20000101")

                # Auftrennen von Vor- und Nachnamen (je nach Format)
                if hasattr(name, "family_name") and hasattr(name, "given_name"):
                    last = name.family_name
                    first = name.given_name
                else:
                    name_str = str(name)
                    parts = name_str.split("^")
                    last = parts[0] if len(parts) > 0 else "Doe"
                    first = parts[1] if len(parts) > 1 else "John"

                patient_info.append({
                    "first": first,
                    "last": last,
                    "dob": birth_date,
                    "studydate": study_date
                })
                readoutcomplete = True

            except Exception as e:
                print(f"Fehler bei {file_path}: {e}")

            if (readoutcomplete):
                return patient_info
    messagebox.showwarning("Keine verwertbaren DICOM-Daten gefunden!")    
    return

def import_cd():
    global dicom_folder, current_patient_info
    # Benutzer wählt ein Verzeichnis aus
    selected_folder = filedialog.askdirectory(title="Bitte Ordner mit DICOM-Daten auswählen")

    if not selected_folder:
        return  # Abgebrochen

    # Prüfen, ob der gewählte Ordner selbst "DICOM" heißt
    if os.path.basename(selected_folder).lower() == "dicom":
        dicom_folder = selected_folder
    else:
        # Rekursive Suche nach einem Unterordner namens "DICOM"
        dicom_folder = None
        for root, dirs, _ in os.walk(selected_folder):
            for d in dirs:
                if d.lower() == "dicom":
                    dicom_folder = os.path.join(root, d)
                    break
            if dicom_folder:
                break

    # Ergebnis ausgeben
    if dicom_folder and os.path.isdir(dicom_folder):
        print(f"DICOM-Ordner gefunden: {dicom_folder}")
        infos = extract_patient_info_from_folder(dicom_folder)
        for info in infos:
            current_patient_info = info
            print('------------------')

            # Nachname
            last = info.get('last', '')
            print('Nachname: ' + last)
            last_name_entry.delete(0, ctk.END)
            last_name_entry.insert(0, last)

            # Vorname
            first = info.get('first', '')
            print('Vorname: ' + first)
            first_name_entry.delete(0, ctk.END)
            first_name_entry.insert(0, first)

            # Geburtsdatum
            dob = info.get('dob', '')
            print('DOB: ' + dob)
            dob_entry.delete(0, ctk.END)
            dob_entry.insert(0, dob)

            # Studiendatum
            studydate = info.get('studydate', '')
            print('Study Date: ' + studydate)
            studydate_entry.delete(0, ctk.END)
            studydate_entry.insert(0, studydate)

            # Pfad            
            print('Path: ' + dicom_folder)
            cd_path.configure(text=dicom_folder)

            # Ordnergröße
            size_mb = get_folder_size(dicom_folder)
            print(f"Ordnergröße: {size_mb:.2f} MB")            
            folder_size_label.configure(text=f"{size_mb} MB")

    else:
        messagebox.showwarning("Kein DICOM-Ordner", "Es wurde kein 'DICOM'-Verzeichnis gefunden.")

def copy_dicom_folder():
    global dicom_folder, current_patient_info
    print(dicom_folder)
    if not dicom_folder or not os.path.isdir(dicom_folder):
        messagebox.showerror("Fehler", "Kein gültiger DICOM-Ordner geladen.")
        return

    info = current_patient_info
    if not info:
        messagebox.showerror("Fehler", "Keine Patientendaten verfügbar.")
        return

    # Zielpfad erzeugen
    folder_name = f"{info['studydate']}-{info['dob']}-{info['last']}-{info['first']}"
    target_path = os.path.join(destination_path, folder_name)

    if os.path.exists(target_path):
        messagebox.showwarning("Ordner existiert", f"Der Zielordner:\n{os.path.basename(target_path)}\nexistiert bereits.")
        return

    try:
        shutil.copytree(dicom_folder, target_path)
        messagebox.showinfo("Kopiert", f"DICOM-Daten wurden erfolgreich nach\n{os.path.basename(target_path)}\nkopiert.")
    except Exception as e:
        messagebox.showerror("Fehler beim Kopieren", str(e))
        return

    # Eingabefelder zurücksetzen
    for entry in [first_name_entry, last_name_entry, dob_entry, studydate_entry]:
        entry.delete(0, ctk.END)

    cd_path.configure(text="unbekannt")
    folder_size_label.configure(text="unbekannt")
    update_disk_usage_display()

# Hauptfenster
app = ctk.CTk()
app.title("DICOM-Importer")
app.geometry("640x600")
app.minsize(480, 400)

# Überschrift
label = ctk.CTkLabel(
    app,
    text="DICOM-Importer",
    font=ctk.CTkFont(size=20, weight="bold")
)
label.pack(pady=15)

# Container-Frame
main_frame = ctk.CTkFrame(app)
main_frame.pack(padx=20, pady=10, fill="both", expand=True)

# Eingabefeld-Bereich
form_frame = ctk.CTkFrame(main_frame, fg_color="transparent")
form_frame.pack(fill="x", padx=15, pady=10, anchor="nw")

def labeled_entry(master, label_text):
    container = ctk.CTkFrame(master, fg_color="transparent")
    container.pack(fill="x", pady=6)

    label = ctk.CTkLabel(container, text=label_text, width=140, anchor="w")
    label.pack(side="left", padx=(0, 10))

    entry = ctk.CTkEntry(container, justify="left")
    entry.pack(side="left", fill="x", expand=True)
    return entry

first_name_entry = labeled_entry(form_frame, "Vorname:")
last_name_entry = labeled_entry(form_frame, "Nachname:")
dob_entry = labeled_entry(form_frame, "Geburtsdatum (YYYYMMDD):")
studydate_entry = labeled_entry(form_frame, "Studien-Datum (YYYYMMDD):")

# Info-Bereich für Pfad und Größe
info_frame = ctk.CTkFrame(main_frame)
info_frame.pack(fill="x", padx=15, pady=(15, 10), anchor="nw")

def labeled_info(master, title, initial="unbekannt"):
    title_label = ctk.CTkLabel(master, text=title, anchor="w")
    title_label.pack(fill="x", padx=5, pady=(0, 0))
    value_label = ctk.CTkLabel(master, text=initial, text_color="gray", anchor="w")
    value_label.pack(fill="x", padx=5, pady=(0, 5))
    return value_label

cd_path = labeled_info(info_frame, "Pfad zum DICOM-Ordner:")
folder_size_label = labeled_info(info_frame, "Ordnergröße:")

# Button-Bereich
button_frame = ctk.CTkFrame(main_frame, fg_color="transparent")
button_frame.pack(pady=20)

import_button = ctk.CTkButton(button_frame, text="CD auslesen", command=import_cd, width=220)
import_button.pack(side="left", padx=(0, 10))

copy_button = ctk.CTkButton(button_frame, text="CD kopieren", command=copy_dicom_folder, width=220)
copy_button.pack(side="left")

# Speicherplatzanzeige unterhalb
space_frame = ctk.CTkFrame(app)
space_frame.pack(fill="x", padx=20, pady=(0, 10))

disk_label = ctk.CTkLabel(space_frame, text="Speicherplatz auf Zielvolume:")
disk_label.pack(anchor="w", padx=5)

disk_progress = ctk.CTkProgressBar(space_frame, orientation="horizontal")
disk_progress.pack(fill="x", padx=5, pady=5)

disk_info_label = ctk.CTkLabel(space_frame, text="Nicht verfügbar", text_color="gray")
disk_info_label.pack(anchor="w", padx=5)

# Starten
update_disk_usage_display()
app.mainloop()