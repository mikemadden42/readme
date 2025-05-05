# Build most projects that use cmake.
rm -rf build; mkdir build; cd build; cmake -GNinja -DCMAKE_BUILD_TYPE=Release .. 2>&1 | tee config.log; ninja

# Enable examples & build nvbench.
rm -rf build; mkdir build; cd build; cmake -DNVBench_ENABLE_EXAMPLES=ON -GNinja -DCMAKE_BUILD_TYPE=Release .. 2>&1 | tee config.log; ninja

# Build & install a newer version of cmake.
rm -rf build; mkdir build; cd build; cmake -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$HOME/opt/cmake-3.31.7 .. 2>&1 | tee config.log; ninja; ninja install

export PATH=$HOME/opt/cmake/bin:$PATH
