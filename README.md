# Atmos ☁️
### **Apple Swift Student Challenge 2026 Submission**

**Atmos** is an immersive iOS application that redefines how users interact with environmental data. Developed with a **"design-first" philosophy**, Atmos blends high-fidelity SwiftUI animations with real-time data to create a minimalist, intuitive atmosphere for the modern user.

---

## 🚀 Project Overview
As a Computer Science student at **Central Michigan University**, I developed Atmos to explore the intersection of data-driven functionality and expressive UI/UX. The app focuses on providing **contextual awareness** by leveraging Apple’s latest frameworks to provide a seamless, fluid experience.

## ✨ Key Features
* **Immersive Visuals:** A dynamic interface that responds to environmental changes using custom SwiftUI transitions and high-frame-rate animations.
* **Data-Driven Logic:** Integrates real-time insights based on the user's current environment.
* **Accessibility First:** Built with **Dynamic Type** and **VoiceOver** support, ensuring the experience is inclusive for all users.
* **Modern Architecture:** Implements a clean **MVVM (Model-View-ViewModel)** pattern for scalability and testability.

## 🛠 Technical Stack
* **Frontend:** Swift 5.10+, SwiftUI, Combine Framework.
* **Backend & AI:** Python (FastAPI/Flask), PyTorch, Scikit-learn.
* **Architecture:** MVVM on iOS with a RESTful Microservices backend.
* **Data Management:** CoreData for local persistence and SQL for cloud storage.

---

## 🧠 AI & Machine Learning Backend
Atmos isn't just a weather app; it utilizes a **Python-based backend** to process complex environmental patterns. 



### **Predictive Modeling**
* **ML Integration:** Uses a custom-trained **Random Forest** model (or Neural Network) to predict [insert specific goal, e.g., local atmospheric changes] based on historical sensor data.
* **Python API:** A high-performance **FastAPI** backend serves as the bridge between the ML models and the iOS client.
* **Data Processing:** Leverages **Pandas** and **NumPy** for real-time telemetry cleaning and feature engineering.

```python
# Example of the Predictive Logic in the Python Backend
from fastapi import FastAPI
import joblib

app = FastAPI()
model = joblib.load("atmos_ml_model.pkl")

@app.post("/predict")
async def get_prediction(data: EnvironmentalData):
    # ML Inference for atmospheric trends
    prediction = model.predict([data.features])
    return {"trend": prediction[0]}
