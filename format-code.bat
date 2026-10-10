@echo off

chcp 65001 >nul
setlocal
pushd "%~dp0"
if errorlevel 1 exit /b 1

where dfmt >nul 2>nul
if errorlevel 1 (
    echo 未找到 dfmt，请先安装并加入 PATH
    popd
    exit /b 1
)

echo.
echo 开始格式化代码
for %%d in (source source-test) do (
    echo 正在格式化目录：%%d
    dfmt --config "%CD%" --inplace "%%d"
    if errorlevel 1 (
        echo D 代码格式化失败，已停止
        popd
        exit /b 1
    )
)

echo.
echo 代码格式化完成
popd
exit /b 0
