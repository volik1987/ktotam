"""SFace (ONNX, OpenCV Zoo) → Core ML: macos/models/SFace.mlmodelc.

Запуск (python 3.12, pip install torch onnx onnx2torch coremltools opencv-python pillow):
  python macos/tools/convert_sface.py windows/models/face_recognition_sface_2021dec.onnx SFace.mlpackage <папка с jpg-кропами лиц>
затем скомпилировать: python -c "import coremltools as ct; print(ct.models.utils.compile_model(\"SFace.mlpackage\"))"
Скрипт сверяет вектор Core ML с cv2.FaceRecognizerSF.feature (косинус должен быть ≈ 1).
Вход — картинка RGB 112×112 без нормализации (как blobFromImage(img, 1, 112×112, 0, swapRB=true) в OpenCV).
"""
import sys, numpy as np, onnx, torch, coremltools as ct, cv2
from onnx2torch import convert
src, out = sys.argv[1], sys.argv[2]
m = onnx.load(src)
print("inputs", [(i.name, [d.dim_value for d in i.type.tensor_type.shape.dim]) for i in m.graph.input])
tm = convert(m).eval()
x = torch.rand(1,3,112,112)*255
tr = torch.jit.trace(tm, x)
ml = ct.convert(tr, inputs=[ct.ImageType(name="image", shape=(1,3,112,112), color_layout=ct.colorlayout.RGB, scale=1.0, bias=[0,0,0])],
                outputs=[ct.TensorType(name="feature")], minimum_deployment_target=ct.target.macOS13, convert_to="mlprogram",
                compute_precision=ct.precision.FLOAT32)
ml.short_description = "SFace face recognition (OpenCV Zoo, Apache 2.0)"
ml.save(out)
# сверка с OpenCV
rec = cv2.FaceRecognizerSF.create(src, "")
from PIL import Image
rng = np.random.default_rng(0)
import glob
crops = sorted(glob.glob(sys.argv[3]+"/*.jpg"))[:6]
for p in crops:
    bgr = cv2.resize(cv2.imread(p), (112,112))
    a = rec.feature(bgr).flatten()
    rgb = Image.fromarray(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))
    b = np.array(ml.predict({"image": rgb})["feature"]).flatten()
    print(p.split("/")[-1], "cos", float(a@b/np.linalg.norm(a)/np.linalg.norm(b)))
