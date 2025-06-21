#!/usr/bin/env python3
 
import os
import shutil
import customtkinter as ctk
import tkinter as tk
from tkinter import filedialog, messagebox
import pydicom
import subprocess
import time
import threading
import sys
import configparser
import logging


log_file = os.path.join(os.path.expanduser("~"), "dicom-importer.log")

# Logger konfigurieren
logger = logging.getLogger("dicom_importer")
logger.setLevel(logging.DEBUG)

# Formatter
formatter = logging.Formatter("%(asctime)s - %(levelname)s - %(message)s")

# FileHandler
file_handler = logging.FileHandler(log_file)
file_handler.setLevel(logging.DEBUG)
file_handler.setFormatter(formatter)

# StreamHandler (stderr)
stream_handler = logging.StreamHandler(sys.stderr)
stream_handler.setLevel(logging.DEBUG)
stream_handler.setFormatter(formatter)

# add handler to logger
logger.addHandler(file_handler)
logger.addHandler(stream_handler)

# Global variables
dicom_folder = None
current_patient_info = None

# Fallback
destination_path = "/tmp"

# Paths
home_dir = os.path.expanduser("~")
home_config_file = os.path.join(home_dir, ".dicom-importer")
program_dir = os.path.dirname(os.path.abspath(__file__))
program_config_file = os.path.join(program_dir, ".dicom-importer")  

# Choose the first available config file
config_file = None
if os.path.exists(program_config_file):
    config_file = program_config_file
    logger.info("Using config file in program dirctory")
elif os.path.exists(home_config_file):
    config_file = home_config_file
    logger.info("Using config file in home dirctory")

# Read the destination path
if config_file:
    try:
        config = configparser.ConfigParser()
        config.read(config_file)
        destination_path = config.get("settings", "destination_path", fallback=destination_path)
    except Exception as e:
        logger.warning(f"Could not read destination path from {config_file}: {e}")

logger.info(f"Destination path: {destination_path}")


# Define main application window and appearance
app = ctk.CTk()
app.title("DICOM-Importer")


ctk.set_appearance_mode("System")
ctk.set_default_color_theme("blue")

def resource_path(relative_path):
    """ Get absolute path to resource, works for dev and for PyInstaller """
    if hasattr(sys, '_MEIPASS'):
        return os.path.join(sys._MEIPASS, relative_path)
    return os.path.join(os.path.abspath("."), relative_path)

icon_path = resource_path("icon.png")
logger.info(f"Icon path: {icon_path}")
icon_image = tk.PhotoImage(file=icon_path)
app.iconphoto(True, icon_image)

# Returns disk usage (used, free, total, percent used)
def get_disk_usage_percent(path):
    try:
        total, used, free = shutil.disk_usage(path)
        percent_used = int(used / total * 100)
        return used, free, total, percent_used
    except Exception as e:
        logger.error(f"Error getting disk usage: {e}")
        return 0, 0, 0, 0

# Updates the GUI to show available disk space
def update_disk_usage_display():
    used, free, total, percent = get_disk_usage_percent(destination_path)
    disk_progress.set(percent / 100)
    total_gb = total / (1024**3)
    free_gb = free / (1024**3)
    disk_info_label.configure(
        text=f"Free: {free_gb:.1f} GB of {total_gb:.1f} GB ({100 - percent}% free)"
    )

# Returns folder size in MB
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
        size_mb = size_kb // 1024
        return size_mb
    except Exception as e:
        logger.error(f"Error determining folder size: {e}")
        return 0.0

# Extracts DICOM metadata (name, DOB, modality, etc.) from folder
def extract_patient_info_from_folder(folder_path):
    patient_info = []
    readoutcomplete = False
    for root, _, files in os.walk(folder_path):
        for file in files:            
            file_path = os.path.join(root, file)
            try:
                ds = pydicom.dcmread(file_path, stop_before_pixels=True)
                name = ds.get("PatientName", "Doe^John")
                birth_date = ds.get("PatientBirthDate", "19000101")
                study_date = ds.get("StudyDate", "20000101")
                modality = ds.get("Modality", "NA")
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
                    "studydate": study_date,
                    "modality": modality
                })
                readoutcomplete = True
            except Exception as e:
                logger.error(f"Error reading {file_path}: {e}")
            if readoutcomplete:
                return patient_info
    messagebox.showwarning("No usable DICOM data found!", "")
    return

# Prompts user to select DICOM folder and extracts info
def import_cd():
    global dicom_folder, current_patient_info
    selected_folder = filedialog.askdirectory(title="Bitte Ordner mit DICOM-Daten auswählen")
    if not selected_folder:
        return
    if os.path.basename(selected_folder).lower() == "dicom":
        dicom_folder = selected_folder
    else:
        dicom_folder = None
        for root, dirs, _ in os.walk(selected_folder):
            for d in dirs:
                if d.lower() == "dicom":
                    dicom_folder = os.path.join(root, d)
                    break
            if dicom_folder:
                break
    if dicom_folder and os.path.isdir(dicom_folder):
        logger.info(f"DICOM folder found: {dicom_folder}")
        infos = extract_patient_info_from_folder(dicom_folder)        
        for info in infos:
            current_patient_info = info
            last_name_entry.delete(0, ctk.END)
            last_name_entry.insert(0, info.get('last', ''))
            logger.info(f"Nachname: {info.get('last', '')}")          
            first_name_entry.delete(0, ctk.END)
            first_name_entry.insert(0, info.get('first', ''))
            logger.info(f"Vorname: {info.get('first', '')}")
            dob_entry.delete(0, ctk.END)
            dob_entry.insert(0, info.get('dob', ''))
            logger.info(f"Geburtsdatum: {info.get('dob', '')}")
            studydate_entry.delete(0, ctk.END)
            studydate_entry.insert(0, info.get('studydate', ''))
            logger.info(f"Studien-Datum: {info.get('studydate', '')}")
            modality_entry.delete(0, ctk.END)
            modality_entry.insert(0, info.get('modality', ''))
            logger.info(f"Untersuchungsart: {info.get('modality', '')}")
            cd_path.configure(text=dicom_folder)
            folder_size_label.configure(text=f"{get_folder_size(dicom_folder)} MB")
            logger.info(f"Ordnergröße: {get_folder_size(dicom_folder)} MB")
    else:
        messagebox.showwarning("Kein DICOM-Ordner", "Es wurde kein 'DICOM'-Verzeichnis gefunden.")

def show_copy_progress(src_folder, dst_folder):
    progress_dialog = ctk.CTkToplevel()
    progress_dialog.title("Daten werden kopiert...")
    progress_dialog.geometry("400x180")
    progress_dialog.grab_set()

    label = ctk.CTkLabel(progress_dialog, text="Daten werden kopiert...")
    logger.info(f"Kopieren von {src_folder} nach {dst_folder}")
    label.pack(pady=(10, 0))

    progress_bar = ctk.CTkProgressBar(progress_dialog)
    progress_bar.pack(padx=20, pady=(10, 2), fill="x")
    progress_bar.set(0)

    progress_label = ctk.CTkLabel(progress_dialog, text="0 MB")
    progress_label.pack()

    cancel_button = ctk.CTkButton(progress_dialog, text="Abbrechen", fg_color="red", hover_color="#aa0000")
    cancel_button.pack(pady=10)

    total_bytes = get_folder_size(src_folder) * 1024 * 1024
    copied_bytes = 0
    cancel_event = threading.Event()

    def on_cancel():
        cancel_event.set()
        cancel_button.configure(state="disabled")
        label.configure(text="Abbruch wird durchgeführt...")
        logger.info("Kopieren abgebrochen.")

    cancel_button.configure(command=on_cancel)

    def copy_files():
        nonlocal copied_bytes
        try:
            for root, dirs, files in os.walk(src_folder):
                if cancel_event.is_set():
                    break
                rel_path = os.path.relpath(root, src_folder)
                dst_path = os.path.join(dst_folder, rel_path)
                os.makedirs(dst_path, exist_ok=True)

                for f in files:
                    if cancel_event.is_set():
                        break
                    src_file = os.path.join(root, f)
                    dst_file = os.path.join(dst_path, f)
                    try:
                        shutil.copy2(src_file, dst_file)
                        bytes_copied = os.path.getsize(src_file)
                        copied_bytes += bytes_copied
                        mb_copied = copied_bytes / (1024 ** 2)
                        mb_total = total_bytes / (1024 ** 2)
                        progress = copied_bytes / total_bytes

                        app.after(0, lambda p=progress, m=mb_copied, t=mb_total:
                                  update_progress(p, m, t))
                        time.sleep(0.02)
                    except Exception as e:
                        logger.error(f"Fehler beim Kopieren: {e}")

            if cancel_event.is_set():
                app.after(0, lambda: cancel_copy(progress_dialog, dst_folder))
            else:
                app.after(0, lambda: finish_copy(progress_dialog, dst_folder))
        except Exception as e:
            logger.error(f"Kopierfehler: {e}")

    def update_progress(progress, mb_copied, mb_total):
        progress_bar.set(progress)
        progress_label.configure(text=f"{mb_copied:.1f} MB von {mb_total:.1f} MB")

    def cancel_copy(dialog, path_to_delete):
        try:
            if os.path.exists(path_to_delete):
                shutil.rmtree(path_to_delete)
                logger.info(f"Zielordner gelöscht: {path_to_delete}")
        except Exception as e:
            logger.error(f"Fehler beim Löschen des Zielordners: {e}")
        dialog.destroy()
        messagebox.showwarning("Abgebrochen", "Kopieren wurde abgebrochen und der Zielordner gelöscht.")

    def finish_copy(dialog, dst_folder):
        dialog.destroy()
        messagebox.showinfo("Fertig", f"Kopieren abgeschlossen:\n{dst_folder}")

    threading.Thread(target=copy_files, daemon=True).start()


# Starts copying process and resets form
def copy_dicom_folder():
    global dicom_folder, current_patient_info
    if not dicom_folder or not os.path.isdir(dicom_folder):
        messagebox.showerror("Fehler", "Kein gültiger DICOM-Ordner geladen.")
        return
    info = current_patient_info
    if not info:
        messagebox.showerror("Fehler", "Keine Patientendaten verfügbar.")
        return
    folder_name = f"{info['studydate']}-{info['dob']}-{info['last']}, {info['first']}-{info['modality']}"
    target_path = os.path.join(destination_path, folder_name)

    # Check if destination is writable
    if not os.access(destination_path, os.W_OK):
        messagebox.showerror("Fehler", f"Das Zielverzeichnis ist nicht beschreibbar:\n{destination_path}")
        logger.error(f"Zielverzeichnis nicht beschreibbar: {destination_path}")
        return

    if os.path.exists(target_path):
        messagebox.showwarning("Ordner existiert", f"Der Zielordner existiert bereits:\n{os.path.basename(target_path)}")
        logger.warning(f"Zielordner existiert bereits: {target_path}") 
        return
    try:
        show_copy_progress(dicom_folder, target_path)
    except Exception as e:
        messagebox.showerror("Fehler beim Kopieren", str(e))
        logger.error(f"Fehler beim Kopieren: {e}")
        return
    for entry in [first_name_entry, last_name_entry, dob_entry, studydate_entry, modality_entry]:
        entry.delete(0, ctk.END)
    cd_path.configure(text="unbekannt")
    folder_size_label.configure(text="unbekannt")
    update_disk_usage_display()

# Build UI layout
app.geometry("640x600")
app.minsize(480, 400)
label = ctk.CTkLabel(app, text="DICOM-Importer", font=ctk.CTkFont(size=20, weight="bold"))
label.pack(pady=15)

main_frame = ctk.CTkFrame(app)
main_frame.pack(padx=20, pady=10, fill="both", expand=True)

form_frame = ctk.CTkFrame(main_frame, fg_color="transparent")
form_frame.pack(fill="x", padx=15, pady=10, anchor="nw")

# Creates labeled entry field
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
modality_entry = labeled_entry(form_frame, "Untersuchungsart:")

info_frame = ctk.CTkFrame(main_frame)
info_frame.pack(fill="x", padx=15, pady=(15, 10), anchor="nw")

# Creates labeled information field
def labeled_info(master, title, initial="unbekannt"):
    title_label = ctk.CTkLabel(master, text=title, anchor="w")
    title_label.pack(fill="x", padx=5, pady=(0, 0))
    value_label = ctk.CTkLabel(master, text=initial, text_color="gray", anchor="w")
    value_label.pack(fill="x", padx=5, pady=(0, 5))
    return value_label

cd_path = labeled_info(info_frame, "Pfad zum DICOM-Ordner:")
folder_size_label = labeled_info(info_frame, "Ordnergröße:")

button_frame = ctk.CTkFrame(main_frame, fg_color="transparent")
button_frame.pack(pady=20)

import_button = ctk.CTkButton(button_frame, text="Daten auslesen", command=import_cd, width=220)
import_button.pack(side="left", padx=(0, 10))

copy_button = ctk.CTkButton(button_frame, text="CD kopieren", command=copy_dicom_folder, width=220)
copy_button.pack(side="left")

space_frame = ctk.CTkFrame(app)
space_frame.pack(fill="x", padx=20, pady=(0, 10))

disk_label = ctk.CTkLabel(space_frame, text="Speicherplatz auf Zielvolume:")
disk_label.pack(anchor="w", padx=5)

disk_progress = ctk.CTkProgressBar(space_frame, orientation="horizontal")
disk_progress.pack(fill="x", padx=5, pady=5)

disk_info_label = ctk.CTkLabel(space_frame, text="Nicht verfügbar", text_color="gray")
disk_info_label.pack(anchor="w", padx=5)

# Initialize disk info and start application
update_disk_usage_display()
    
app.mainloop()
