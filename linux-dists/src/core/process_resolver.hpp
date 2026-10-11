#pragma once
#include "types.hpp"

namespace reqly {
class ProcessResolver {
public:
    ProcessOrigin resolve(int clientPort);
private:
    unsigned long findSocketInode(int clientPort);
    ProcessOrigin findProcessByInode(unsigned long inode);
};
}
