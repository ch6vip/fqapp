# The optional JNI plugin is unused by the Linux product; host JDK discovery
# must not change the package payload or add a Java runtime dependency.
set(CMAKE_DISABLE_FIND_PACKAGE_JNI TRUE)
