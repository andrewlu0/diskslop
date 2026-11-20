use std::ops::{Index, IndexMut};
use std::sync::Arc;

const PAGE: usize = 128;

/// Snapshot edits copy just the pages containing modified rows.
#[derive(Clone)]
pub(crate) struct Pages<T> {
    pages: Vec<Arc<Vec<T>>>,
    len: usize,
}

impl<T> From<Vec<T>> for Pages<T> {
    fn from(values: Vec<T>) -> Self {
        let len = values.len();
        let mut rows = values.into_iter();
        let pages = (0..len.div_ceil(PAGE))
            .map(|_| Arc::new(rows.by_ref().take(PAGE).collect()))
            .collect();
        Self { pages, len }
    }
}
impl<T> Pages<T> {
    pub(crate) fn len(&self) -> usize {
        self.len
    }
    pub(crate) fn is_empty(&self) -> bool {
        self.len == 0
    }
    pub(crate) fn get(&self, index: usize) -> Option<&T> {
        self.pages.get(index / PAGE)?.get(index % PAGE)
    }
    pub(crate) fn iter(&self) -> impl Iterator<Item = &T> {
        self.pages.iter().flat_map(|page| page.iter())
    }
}
impl<T: Clone> Pages<T> {
    pub(crate) fn grow(&mut self, len: usize, value: T) {
        while self.len < len {
            let offset = self.len % PAGE;
            if offset == 0 {
                self.pages.push(Arc::new(Vec::with_capacity(PAGE)));
            }
            let count = (PAGE - offset).min(len - self.len);
            Arc::make_mut(self.pages.last_mut().unwrap()).resize(offset + count, value.clone());
            self.len += count;
        }
    }

    pub(crate) fn iter_mut(&mut self) -> impl Iterator<Item = &mut T> {
        self.pages
            .iter_mut()
            .flat_map(|page| Arc::make_mut(page).iter_mut())
    }
}
impl<T> Index<usize> for Pages<T> {
    type Output = T;
    fn index(&self, index: usize) -> &T {
        &self.pages[index / PAGE][index % PAGE]
    }
}
impl<T: Clone> IndexMut<usize> for Pages<T> {
    fn index_mut(&mut self, index: usize) -> &mut T {
        &mut Arc::make_mut(&mut self.pages[index / PAGE])[index % PAGE]
    }
}
