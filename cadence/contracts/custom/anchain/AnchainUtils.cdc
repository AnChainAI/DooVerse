/**
  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
**/
import MetadataViews from "../../standard/MetadataViews.cdc"

pub contract AnchainUtils {

  // One inconvenience with the new NFT metadata standard is that you 
  // cannot return nil from `borrowViewResolver(id: UInt64)`. Consider 
  // the case when we call the function with an ID that doesn't exist 
  // in the collection. In this scenario, we're forced to either panic 
  // or let a dereference error occcur, which may not be preferred in 
  // some situations. In order to prevent these errors from occuring we 
  // could write more code to check if the ID exists via getIDs() (cringe). 
  // OR we can simply use the interface below. This interface should help 
  // us resolve (no pun intended) the unwanted behavior described above 
  // and provides a much cleaner (and efficient) way of handling errors.
  //
  pub resource interface ResolverCollection {
    pub fun borrowViewResolverSafe(id: UInt64): &{MetadataViews.Resolver}?
    pub fun getSortedIDs(): [UInt64]
  }

  // File
  // A MetadataViews.File with an added file extension. 
  //
  pub struct File {

    // The file extension
    //
    pub let ext: String

    // The file thumbnail
    //
    pub let thumbnail: AnyStruct{MetadataViews.File}

    init(
      ext: String
      thumbnail: AnyStruct{MetadataViews.File}
    ) {
      self.ext = ext
      self.thumbnail = thumbnail
    }

  }

  // binarySearch
  // Returns the index of where `key` should be inserted into `arr` to maintain
  // the ordering of `arr`.
  //
  pub fun binarySearch(_ arr: [UInt64], _ key: UInt64): Int {
    if arr.length <= 0 {
      return 0
    }
    if key > arr[arr.length - 1] {
      return arr.length
    }
    var lft = 0
    var rgt = arr.length - 1
    var mid = lft + ((rgt - lft) / 2)
    while lft <= rgt {
      mid = lft + ((rgt - lft) / 2)
      if arr[mid] == key {
        return mid
      } else if arr[mid] < key {
        lft = mid + 1
      } else {
        rgt = mid - 1
      }
    }
    return mid
  }

}