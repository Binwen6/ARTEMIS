# xjtu-COMP500127-proj

> **项目全称**：Accelerated Ray Tracing and Enhanced Marching for Integrated flocking with point cloudS
> **核心目标**：实现从“文字/图像意向”到“动态感性三维实体”的全链路生成与实时交互展示。

---

## 一、 项目背景与动机

在传统图形学中，**点云 (Point Clouds)** 通常被视为静态的、离散的数据扫描结果；而 **Boids (群落模拟)** 则常用于散乱的粒子效果。

本项目的**核心直觉 (Intuition)** 是：**“如果点云不再是死板的像素，而是具有生命力的智能粒子呢？”**
我们希望构建一个系统，能让成千上万个具备自主意识的粒子（Boids），通过群体行为，动态地“坍缩”成由 AI 生成的高级语义形状。这不仅是图形学的展示，更是一种“数字生命化”的尝试。

---

## 二、 核心技术栈脉络

项目的逻辑可以概括为一个 **“从虚到实，由点及面”** 的过程：

### 1. 语义降维：AI 生成管线 (The Generative Pipeline)
*   **思路**：将人类的抽象语言转化为三维离散坐标。
*   **环节**：`LLM (Prompt Engineering)` -> `Stable Diffusion / DALL-E (图像生成)` -> `Point-E (点云扩散模型)`。
*   **产出**：一组带颜色信息的四千量级点云坐标（`.npy` 文件），作为粒子群落的“终态蓝图”。

### 2. 数字生命：GPU 端 Boids 模拟
*   **底层知识**：基于 Reynolds 经典群落三大定律（Separation, Alignment, Cohesion）。
*   **关键改进 (Target Arrival)**：我们额外引入了 **Arrival (抵达)** 规则。每个粒子被分配到 AI 生成点云中的一个目标槽位。
*   **GPU 加速 (OpenCL)**：由于 $O(N^2)$ 的暴力距离检索在 CPU 上无法实时运行，我们将其迁移至 OpenCL 内核。利用高性能并行计算，使数千个粒子在每秒内交互万次。

### 3. 几何融合：Ray Marching 与 Smooth Union
*   **渲染抉择**：如果只渲染球体，粒子感太强，缺乏视觉冲击。
*   **关键技术 (SDF & Smooth Min)**：我们引入了有向距离场 (SDF) 渲染。
    *   **Ray Marching**：通过步进法寻找粒子表面的交点。
    *   **Smooth Union (平滑并集)**：这是项目的灵魂技巧。通过 `smooth_min` 函数，当两个粒子靠近时，它们的表面会像磁流体或水滴一样自动融合。这种“肉感”的视觉效果让群落看起来像是一个整体的有机生命体，而非散沙。

### 4. 性能之梯：BVH 与 Morton 编码
*   **痛点**：Ray Marching 在数千个 SDF 源下极其缓慢。
*   **解决方案**：
    *   **Morton 编码 (Z-Order)**：将粒子坐标映射为一维编码，使空间邻近的点在显存中也趋于物理邻近，极大优化 L1/L2 缓存命中率。
    *   **BVH (层次包围盒)**：构建二叉树剔除大量无关计算，确保光线步进时只遍历必要的空间区域。

---

## 三、 关键底层技巧


### 1. CL-GL Interop (零拷贝互操作)
*   **知识点**：数据不需要在显卡和内存之间搬运。
*   **逻辑**：OpenCL 算完的位置和颜色直接写进 OpenGL 的纹理缓存，并在下一帧直接用于渲染。这消除了 PCI-E 带宽瓶颈，是实现“千万粒子实时感”的技术基石。

### 2. 局部内存与同步 (Barrier Synchronization)
*   **代码体现**：`local float3 localBuffer[WORK_GROUP_SIZE]`。
*   **价值**：这是 GPU 编程的高阶技巧。将频繁访问的粒子数据先“拉取”到 Work Group 的共享内存中，大幅降低对显存 (Global Memory) 的高延迟访问。

### 3. 实时 SDF 场构建
*   **技巧**：在 `raymarch.cl` 中，我们并没有维护静态的格点，而是动态地根据粒子实时位置计算场强。这意味着我们的“表面”是百分之百精确且实时响应 Boids 加速度变化的。

---

## 四、 总结：本项目的思路闭环

1.  **输入**：一段文字或一张图。
2.  **生成**：确定 3D 目标点云。
3.  **驱动**：Boids 算法驱动数千个粒子在 GPU 上通过复杂的物理力相互竞争、避障并最终向目标靠拢。
4.  **升华**：Ray Marching 结合 `smooth_min` 将离散点升华为动态融合的流体曲面。
5.  **呈现**：最终在用户面前展现出如梦似幻、不断演变的 3D 视觉奇观。

---

# 复现指南

本指南旨在帮助你快速搭建并运行集成 Python 深度学习（Point-E） 与 C++ / OpenCL / OpenGL (底层渲染) 的混合项目。

1. 设备与系统要求 (System Requirements)
项目核心涉及点云生成（深度学习）与粒子渲染（高性能计算），对硬件驱动有特定要求。
操作系统支持

|平台	| 支持状态	| 备注 |
| -----| -----| ----|
|Windows	|强烈推荐	| 完全原生支持。拥有完善的 OpenCL/OpenGL 驱动，兼容性极佳，体验最稳定。|
|macOS	| 支持 (有局限)	| 支持编译运行，项目已针对 Apple 芯片做兼容处理。但由于 Apple 已弃用 OpenCL/OpenGL，新版本系统（M 系列芯片）可能出现 API 警告且无法享受 Metal 加速。|

环境依赖
```
• Python: 3.8+（推荐 3.9，用于 Point-E 运行）
• C++ 编译器: 支持 C++ 17 (GCC / Clang / MSVC)
• 构建工具: CMake 3.16.1+
• 底层库: • GPU 驱动自带的 OpenCL (\ge 1.2) • OpenGL (\ge 3.3) • GLFW 3.3、ZLIB
• macOS 安装命令: brew install cmake glfw zlib
```

2. Step-by-Step 复现指南
复现流程分为：Python 端生成点云 与 C++ 端执行粒子渲染。
A. AI 点云生成端 (Python)
利用 OpenAI 的 Point-E 将图片或文本转化为 3D 空间的离散点云坐标（.npy 格式）。

```
1. 配置 Python 环境 建议使用 Conda 创建独立环境： conda create -n artemis_env python=3.9 conda activate artemis_env
2. 安装 Point-E 及依赖 进入点云生成目录并安装： cd point-e pip install -e . # 注：你可能还需要根据设备前往 PyTorch 官网获取对应的 torch 安装命令
3. 运行并提取点云 启动 Jupyter Notebook： jupyter notebook  • 打开 point_e/examples/image2pointcloud.ipynb 或 text2pointcloud.ipynb。 • 按照代码逻辑运行，最后会输出包含 (x, y, z, r, g, b) 等特征的 Numpy (.npy) 文件。 • 关键步骤：将生成的 .npy 文件放入 CLGLInterop/assets/point-cloud-300M 目录下。
```

B. 核心粒子群落与渲染端 (C++ / OpenCL)
基于 OpenCL 实现 Boids 群落算法，通过 GPU 高并行渲染点云。

```
1. 进入编译目录 cd ../CLGLInterop mkdir build && cd build
2. 编译项目 • Linux / macOS / Windows (MinGW): cmake .. make -j8 • Windows (MSVC): cmake .. cmake --build . --config Release
3. 运行可执行文件 编译成功后，在 build/examples/ 目录下找到 raymarching 文件： ./examples/raymarching
```

3. 交互操作说明 (Interaction Controls)
在渲染窗口激活状态下，你可以通过以下按键进行实时交互：
按键	功能描述
1 - 9	在不同的点云模型之间自由切换（自动加载 assets 目录下的模型）
Q / W / E / R / T / Y / U	切换模型快捷键扩展
P	暂停 / 继续 粒子群运动
SPACE (空格)	切换 Ray marching 绘制模式
鼠标拖拽 / 滚轮	全方位自由视角的摄像机漫游
